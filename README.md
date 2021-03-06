client.go                                                                                           0000664 0001750 0001750 00000054762 14056132746 013445  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package kameleoon

import (
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/cornelk/hashmap"
	"github.com/segmentio/encoding/json"
	"github.com/valyala/fasthttp"

	"development.kameleoon.net/sdk/go-sdk/targeting"
	"development.kameleoon.net/sdk/go-sdk/types"
	"development.kameleoon.net/sdk/go-sdk/utils"
)

const sdkVersion = "1.0.0"

const (
	API_URL     = "https://api.kameleoon.com"
	API_OAUTH   = "https://api.kameleoon.com/oauth/token"
	API_SSX_URL = "https://api-ssx.kameleoon.com"
	REFERENCE   = "0"
)

type Client struct {
	Data *hashmap.HashMap
	Cfg  *Config
	rest restClient

	m            sync.Mutex
	init         bool
	initError    error
	token        string
	experiments  []types.Experiment
	featureFlags []types.FeatureFlag
}

func NewClient(cfg *Config) *Client {
	c := &Client{
		Cfg:  cfg,
		rest: newRESTClient(&cfg.REST),
		Data: new(hashmap.HashMap),
	}
	go c.updateConfig()
	return c
}

func (c *Client) RunWhenReady(cb func(c *Client, err error)) {
	c.m.Lock()
	if c.init || c.initError != nil {
		c.m.Unlock()
		cb(c, c.initError)
		return
	}
	c.m.Unlock()

	t := time.NewTicker(time.Second)
	defer t.Stop()
	for range t.C {
		c.m.Lock()
		if c.init || c.initError != nil {
			c.m.Unlock()
			cb(c, c.initError)
			return
		}
		c.m.Unlock()
	}
}

// TriggerExperiment trigger an experiment.
//
// If such a visitorCode has never been associated with any variation, the SDK returns a randomly selected variation.
// If a user with a given visitor_code is already registered with a variation, it will detect the previously
// registered variation and return the variation_id.
// You have to make sure that proper error handling is set up in your code as shown in the example to the right to
// catch potential exceptions.
//
// returns ExperimentConfigurationNotFound error when experiment configuration is not found
// returns NotActivated error when visitor triggered the experiment, but did not activate it.
// Usually, this happens because the user has been associated with excluded traffic
// returns NotTargeted error when visitor is not targeted by the experiment, as the associated targeting segment conditions were not fulfilled.
// He should see the reference variation
func (c *Client) TriggerExperiment(visitorCode string, experimentID int) (int, error) {
	return c.triggerExperiment(visitorCode, experimentID)
}

func (c *Client) TriggerExperimentTimeout(visitorCode string, experimentID int, timeout time.Duration) (int, error) {
	return c.triggerExperiment(visitorCode, experimentID, timeout)
}

func (c *Client) triggerExperiment(visitorCode string, experimentID int, timeout ...time.Duration) (int, error) {
	var ex types.Experiment
	c.m.Lock()
	for i, e := range c.experiments {
		if e.ID == experimentID {
			ex = e
			break
		}
		if i == len(c.experiments)-1 {
			c.m.Unlock()
			return 0, newErrExperimentConfigNotFound(utils.WriteUint(experimentID))
		}
	}
	c.m.Unlock()
	req := trackingRequest{
		Type:         TrackingRequestExperiment,
		VisitorCode:  visitorCode,
		ExperimentID: ex.ID,
	}
	if !c.Cfg.BlockingMode {
		var data []types.TargetingData
		if cell := c.getDataCell(visitorCode); cell != nil {
			data = cell.Data
		}
		segment, ok := ex.TargetingSegment.(*targeting.Segment)
		if ok && !segment.CheckTargeting(data) {
			return 0, newErrNotActivated(visitorCode)
		}

		threshold := getHashDouble(ex.ID, visitorCode, ex.RespoolTime)
		for k, v := range ex.Deviations {
			threshold -= v
			if threshold >= 0 {
				continue
			}
			req.VariationID = k
			go c.postTrackingAsync(req)
			return utils.ParseUint(k)
		}

		req.VariationID = REFERENCE
		req.NoneVariation = true
		go c.postTrackingAsync(req)
		return 0, newErrNotActivated(visitorCode)
	}

	data := c.selectSendData()
	var sb strings.Builder
	for _, dataCell := range data {
		for i := 0; i < len(dataCell.Data); i++ {
			if _, exist := dataCell.Index[i]; exist {
				continue
			}
			sb.WriteString(dataCell.Data[i].QueryEncode())
			sb.WriteByte('\n')
		}
	}

	r := request{
		URL:         c.buildTrackingPath(c.Cfg.TrackingURL, req),
		Method:      MethodPost,
		ContentType: HeaderContentTypeText,
		ClientHeader: c.Cfg.TrackingVersion,
	}
	if len(timeout) > 0 {
		r.Timeout = timeout[0]
	}
	var id string
	cb := func(resp *fasthttp.Response, err error) error {
		if err != nil {
			return err
		}
		if resp.StatusCode() >= fasthttp.StatusBadRequest {
			return ErrBadStatus
		}
		id = string(resp.Body())
		return err
	}
	c.log("Trigger experiment request: %v", r)
	if err := c.rest.Do(r, cb); err != nil {
		c.log("Failed to trigger experiment: %v", err)
		return 0, err
	}
	switch id {
	case "", "null":
		return 0, newErrNotTargeted(visitorCode)
	case "0":
		return 0, newErrNotActivated(visitorCode)
	}

	return utils.ParseUint(id)
}

// AddData associate various Data to a visitor.
//
// Note that this method doesn't return any value and doesn't interact with the
// Kameleoon back-end servers by itself. Instead, the declared data is saved for future sending via the flush method.
// This reduces the number of server calls made, as data is usually grouped into a single server call triggered by
// the execution of the flush method.
func (c *Client) AddData(visitorCode string, data ...types.Data) {
	// TODO think about memory size and c.Cfg.VisitorDataMaxSize
	//var stats runtime.MemStats
	//runtime.ReadMemStats(&stats)
	t := time.Now()
	td := make([]types.TargetingData, len(data))
	for i := 0; i < len(data); i++ {
		td[i] = types.TargetingData{
			LastActivityTime: t,
			Data:             data[i],
		}
	}
	actual, exist := c.Data.Get(visitorCode)
	if !exist {
		c.Data.Set(visitorCode, &types.DataCell{
			Data:  td,
			Index: make(map[int]struct{}),
		})
		return
	}
	cell, ok := actual.(*types.DataCell)
	if !ok {
		c.Data.Set(visitorCode, &types.DataCell{
			Data:  td,
			Index: make(map[int]struct{}),
		})
		return
	}
	cell.Data = append(cell.Data, td...)
	c.Data.Set(visitorCode, cell)
}

func (c *Client) getDataCell(visitorCode string) *types.DataCell {
	val, exist := c.Data.Get(visitorCode)
	if !exist {
		return nil
	}
	cell, ok := val.(*types.DataCell)
	if !ok {
		return nil
	}
	return cell
}

// TrackConversion on a particular goal
//
// This method requires visitorCode and goalID to track conversion on this particular goal.
// In addition, this method also accepts revenue as a third optional argument to track revenue.
// The visitorCode usually is identical to the one that was used when triggering the experiment.
// This method is non-blocking as the server call is made asynchronously.
func (c *Client) TrackConversion(visitorCode string, goalID int) {
	c.trackConversion(visitorCode, goalID)
}

func (c *Client) TrackConversionRevenue(visitorCode string, goalID int, revenue float64) {
	c.trackConversion(visitorCode, goalID, revenue)
}

func (c *Client) trackConversion(visitorCode string, goalID int, revenue ...float64) {
	conv := types.Conversion{GoalID: goalID}
	if len(revenue) > 0 {
		conv.Revenue = revenue[0]
	}
	c.AddData(visitorCode, &conv)
	c.FlushVisitor(visitorCode)
}

// FlushVisitor the associated data.
//
// The data added with the method AddData, is not directly sent to the kameleoon servers.
// It's stored and accumulated until it is sent automatically by the TriggerExperiment or TrackConversion methods.
// With this method you can manually send it.
func (c *Client) FlushVisitor(visitorCode string) {
	go c.postTrackingAsync(trackingRequest{
		Type:        TrackingRequestData,
		VisitorCode: visitorCode,
	})
}

func (c *Client) FlushAll() {
	go c.postTrackingAsync(trackingRequest{
		Type: TrackingRequestData,
	})
}

// GetVariationAssociatedData returns JSON Data associated with a variation.
//
// The JSON data usually represents some metadata of the variation, and can be configured on our web application
// interface or via our Automation API.
// This method takes the variationID as a parameter and will return the data as a json string.
// It will return an error if the variation ID is wrong or corresponds to an experiment that is not yet online.
//
// returns VariationNotFound error if the variation is not found.
func (c *Client) GetVariationAssociatedData(variationID int) ([]byte, error) {
	c.m.Lock()
	for _, ex := range c.experiments {
		for _, v := range ex.Variations {
			if v.ID == variationID {
				c.m.Unlock()
				return v.CustomJson, nil
			}
		}
	}
	c.m.Unlock()
	return nil, newErrVariationNotFound(utils.WriteUint(variationID))
}

// ActivateFeature activates a feature toggle.
//
// This method takes a visitorCode and feature_key (or featureID) as mandatory arguments to check
// if the specified feature will be active for a given user.
// If such a user has never been associated with this feature flag, the SDK returns a boolean value randomly
// (true if the user should have this feature or false if not).
// If a user with a given visitorCode is already registered with this feature flag, it will detect the previous featureFlag value.
// You have to make sure that proper error handling is set up in your code as shown in the example to the right to catch potential exceptions.
//
// returns FeatureConfigurationNotFound error
// returns NotTargeted error
func (c *Client) ActivateFeature(visitorCode string, featureKey interface{}) (bool, error) {
	return c.activateFeature(visitorCode, featureKey)
}

func (c *Client) ActivateFeatureTimeout(visitorCode string, featureKey interface{}, timeout time.Duration) (bool, error) {
	return c.activateFeature(visitorCode, featureKey, timeout)
}

func (c *Client) activateFeature(visitorCode string, featureKey interface{}, timeout ...time.Duration) (bool, error) {
	ff, err := c.getFeatureFlag(featureKey)
	if err != nil {
		return false, err
	}
	req := trackingRequest{
		Type:         TrackingRequestExperiment,
		VisitorCode:  visitorCode,
		ExperimentID: ff.ID,
	}
	if !c.Cfg.BlockingMode {
		var data []types.TargetingData
		if cell := c.getDataCell(visitorCode); cell != nil {
			data = cell.Data
		}

		segment, ok := ff.TargetingSegment.(*targeting.Segment)
		if ok && !segment.CheckTargeting(data) {
			return false, newErrNotActivated(visitorCode)
		}

		threshold := getHashDouble(ff.ID, visitorCode, nil)
		if threshold <= ff.ExpositionRate {
			if len(ff.VariationsID) > 0 {
				req.VariationID = utils.WriteUint(ff.VariationsID[0])
			}
			go c.postTrackingAsync(req)
			return true, nil
		}
		req.VariationID = REFERENCE
		req.NoneVariation = true
		go c.postTrackingAsync(req)
		return false, nil
	}

	data := c.selectSendData()
	var sb strings.Builder
	for _, dataCell := range data {
		for i := 0; i < len(dataCell.Data); i++ {
			if _, exist := dataCell.Index[i]; exist {
				continue
			}
			sb.WriteString(dataCell.Data[i].QueryEncode())
			sb.WriteByte('\n')
		}
	}
	r := request{
		URL:         c.buildTrackingPath(c.Cfg.TrackingURL, req),
		Method:      MethodPost,
		ContentType: HeaderContentTypeText,
		ClientHeader: c.Cfg.TrackingVersion,
	}
	if len(timeout) > 0 {
		r.Timeout = timeout[0]
	}
	var result string
	cb := func(resp *fasthttp.Response, err error) error {
		if err != nil {
			return err
		}
		if resp.StatusCode() >= fasthttp.StatusBadRequest {
			return ErrBadStatus
		}
		result = string(resp.Body())
		return err
	}
	c.log("Activate feature request: %v", r)
	if err = c.rest.Do(r, cb); err != nil {
		c.log("Failed to get activation: %v", err)
		return false, err
	}
	switch result {
	case "", "null":
		return false, newErrFeatureConfigNotFound(visitorCode)
	}
	return true, nil
}

// GetFeatureVariable retrieves a feature variable.
//
// A feature variable can be changed easily via our web application.
//
// returns FeatureConfigurationNotFound error
// returns FeatureVariableNotFound error
func (c *Client) GetFeatureVariable(featureKey interface{}, variableKey string) (interface{}, error) {
	ff, err := c.getFeatureFlag(featureKey)
	if err != nil {
		return nil, err
	}
	var customJson interface{}
	for _, v := range ff.Variations {
		cj := make(map[string]interface{})
		if err = json.Unmarshal(v.CustomJson, &cj); err != nil {
			continue
		}
		if val, exist := cj[variableKey]; exist {
			customJson = val
		}
	}
	if customJson == nil {
		return nil, newErrFeatureVariableNotFound("Feature variable not found")
	}
	return customJson, nil
}

func (c *Client) getFeatureFlag(featureKey interface{}) (types.FeatureFlag, error) {
	var flag types.FeatureFlag

	c.m.Lock()
	switch key := featureKey.(type) {
	case string:
		for i, featureFlag := range c.featureFlags {
			if featureFlag.IdentificationKey == key {
				flag = featureFlag
				break
			}
			if i == len(c.featureFlags)-1 {
				c.m.Unlock()
				return flag, newErrFeatureConfigNotFound(key)
			}
		}
	case int:
		for i, featureFlag := range c.featureFlags {
			if featureFlag.ID == key {
				flag = featureFlag
				break
			}
			if i == len(c.featureFlags)-1 {
				c.m.Unlock()
				return flag, newErrFeatureConfigNotFound(strconv.Itoa(key))
			}
		}
	default:
		c.m.Unlock()
		return flag, ErrInvalidFeatureKeyType
	}
	c.m.Unlock()

	return flag, nil
}

func (c *Client) GetExperiment(id int) *types.Experiment {
	c.m.Lock()
	for i, ex := range c.experiments {
		if ex.ID == id {
			c.m.Unlock()
			return &c.experiments[i]
		}
	}
	c.m.Unlock()
	return nil
}

func (c *Client) GetFeatureFlag(id int) *types.FeatureFlag {
	c.m.Lock()
	for i, ff := range c.featureFlags {
		if ff.ID == id {
			c.m.Unlock()
			return &c.featureFlags[i]
		}
	}
	c.m.Unlock()
	return nil
}

func (c *Client) log(format string, args ...interface{}) {
	if !c.Cfg.VerboseMode {
		return
	}
	if len(args) == 0 {
		c.Cfg.Logger.Printf(format)
		return
	}
	c.Cfg.Logger.Printf(format, args...)
}

type oauthResp struct {
	Token string `json:"access_token"`
}

func (c *Client) fetchToken() error {
	c.log("Fetching bearer token")
	form := url.Values{
		"grant_type":    []string{"client_credentials"},
		"client_id":     []string{c.Cfg.ClientID},
		"client_secret": []string{c.Cfg.ClientSecret},
	}
	resp := oauthResp{}
	r := request{
		Method:      MethodPost,
		URL:         API_OAUTH,
		ContentType: HeaderContentTypeForm,
		BodyString:  form.Encode(),
	}

	err := c.rest.Do(r, respCallbackJson(&resp))
	if err != nil {
		c.log("Failed to fetch bearer token: %v", err)
		return err
	} else {
		c.log("Bearer Token is fetched: %s", resp.Token)
	}
	var b strings.Builder
	b.WriteString("Bearer ")
	b.WriteString(resp.Token)
	c.m.Lock()
	c.token = b.String()
	c.m.Unlock()
	return nil
}

func (c *Client) updateConfig() {
	c.log("Start-up, fetching is starting")
	err := c.fetchConfig()
	c.m.Lock()
	c.init = true
	c.initError = err
	c.m.Unlock()
	if err != nil {
		c.log("Failed to fetch: %v", err)
		return
	}
	ticker := time.NewTicker(c.Cfg.ConfigUpdateInterval)
	c.log("Scheduled job to fetch configuration is starting")
	for range ticker.C {
		err = c.fetchConfig()
		if err != nil {
			c.log("Failed to fetch: %v", err)
			return
		}
	}
}

func (c *Client) fetchConfig() error {
	if err := c.fetchToken(); err != nil {
		return err
	}
	siteID, err := c.fetchSiteID()
	if err != nil {
		return err
	}
	experiments, err := c.fetchExperiments(siteID)
	if err != nil {
		return err
	}
	featureFlags, err := c.fetchFeatureFlags(siteID)

	c.m.Lock()
	c.experiments = append(c.experiments, experiments...)
	c.featureFlags = append(c.featureFlags, featureFlags...)
	c.m.Unlock()
	return nil
}

func (c *Client) fetchSite() (*types.SiteResponse, error) {
	c.log("Fetching site")
	filter := []fetchFilter{{
		Field:      "code",
		Operator:   "EQUAL",
		Parameters: []string{c.Cfg.SiteCode},
	}}
	res := []types.SiteResponse{{}}
	cb := func(resp *fasthttp.Response, err error) error {
		if err != nil {
			return err
		}
		b := resp.Body()
		if len(b) == 0 {
			return ErrEmptyResponse
		}
		if b[0] == '[' {
			return json.Unmarshal(b, &res)
		}
		return json.Unmarshal(b, &res[0])
	}
	err := c.fetchOne("/sites", fetchQuery{PerPage: 1}, filter, cb)
	if err != nil {
		return nil, err
	}
	if len(res) == 0 {
		return nil, ErrEmptyResponse
	}
	c.log("Sites are fetched: %v", res)
	return &res[0], err
}

type siteResponseID struct {
	ID int `json:"id"`
}

func (c *Client) fetchSiteID() (int, error) {
	c.log("Fetching site id")
	filter := []fetchFilter{{
		Field:      "code",
		Operator:   "EQUAL",
		Parameters: []string{c.Cfg.SiteCode},
	}}
	res := []siteResponseID{{}}
	cb := func(resp *fasthttp.Response, err error) error {
		if err != nil {
			return err
		}
		b := resp.Body()
		if len(b) == 0 {
			return ErrEmptyResponse
		}
		if b[0] == '[' {
			return json.Unmarshal(b, &res)
		}
		return json.Unmarshal(b, &res[0])
	}
	err := c.fetchOne("/sites", fetchQuery{PerPage: 1}, filter, cb)
	if len(res) == 0 {
		return 0, ErrEmptyResponse
	}
	c.log("Sites are fetched: %v", res)
	return res[0].ID, err
}

func (c *Client) fetchExperiments(siteID int, perPage ...int) ([]types.Experiment, error) {
	c.log("Fetching experiments")
	pp := -1
	if len(perPage) > 0 {
		pp = perPage[0]
	}
	var ex []types.Experiment
	filters := []fetchFilter{
		{
			Field:      "siteId",
			Operator:   "EQUAL",
			Parameters: []string{utils.WriteUint(siteID)},
		},
		{
			Field:      "status",
			Operator:   "EQUAL",
			Parameters: []string{"ACTIVE"},
		},
		{
			Field:      "type",
			Operator:   "IN",
			Parameters: []string{string(types.ExperimentTypeServerSide), string(types.ExperimentTypeHybrid)},
		},
	}
	cb := func(resp *fasthttp.Response, err error) error {
		if err != nil {
			return err
		}
		b := resp.Body()
		if len(b) == 0 {
			return ErrEmptyResponse
		}
		res := []types.Experiment{{}}
		if b[0] == '[' {
			err = json.Unmarshal(b, &res)
		} else {
			err = json.Unmarshal(b, &res[0])
		}
		if err != nil {
			return err
		}
		ex = append(ex, res...)
		return nil
	}
	err := c.fetchAll("/experiments", fetchQuery{PerPage: pp}, filters, cb)
	for i := 0; i < len(ex); i++ {
		err = c.completeExperiment(&ex[i])
		if err != nil {
			return nil, err
		}
	}
	c.log("Experiment are fetched: %v", ex)
	return ex, err
}

func (c *Client) completeExperiment(e *types.Experiment) error {
	for _, id := range e.VariationsID {
		variation, err := c.fetchVariation(id)
		if err != nil {
			continue
		}
		e.Variations = append(e.Variations, variation)
	}
	if e.TargetingSegmentID > 0 {
		segment, err := c.fetchSegment(e.TargetingSegmentID)
		if err != nil {
			return err
		}
		if segment.ID == 0 {
			return newErrNotFound("segment id")
		}
		if segment.ConditionsData == nil {
			return newErrNotFound("segment condition data")
		}
		e.TargetingSegment = targeting.NewSegment(segment)
	}
	return nil
}

func (c *Client) fetchVariation(id int) (types.Variation, error) {
	v := types.Variation{}
	var path strings.Builder
	path.WriteString("/variations/")
	path.WriteString(utils.WriteUint(id))
	err := c.fetchOne(path.String(), fetchQuery{}, nil, respCallbackJson(&v))
	return v, err
}

func (c *Client) fetchSegment(id int) (*types.Segment, error) {
	s := &types.Segment{}

	var path strings.Builder
	path.WriteString("/segments/")
	path.WriteString(utils.WriteUint(id))
	err := c.fetchOne(path.String(), fetchQuery{}, nil, respCallbackJson(s))
	return s, err
}

func (c *Client) fetchFeatureFlags(siteID int, perPage ...int) ([]types.FeatureFlag, error) {
	c.log("Fetching feature flags")
	pp := -1
	if len(perPage) > 0 {
		pp = perPage[0]
	}
	var ff []types.FeatureFlag
	filters := []fetchFilter{
		{
			Field:      "siteId",
			Operator:   "EQUAL",
			Parameters: []string{utils.WriteUint(siteID)},
		},
		{
			Field:      "status",
			Operator:   "EQUAL",
			Parameters: []string{"ACTIVE"},
		},
	}
	cb := func(resp *fasthttp.Response, err error) error {
		if err != nil {
			return err
		}
		b := resp.Body()
		if len(b) == 0 {
			return ErrEmptyResponse
		}
		res := []types.FeatureFlag{{}}
		if b[0] == '[' {
			err = json.Unmarshal(b, &res)
		} else {
			err = json.Unmarshal(b, &res[0])
		}
		if err != nil {
			return err
		}
		ff = append(ff, res...)
		return nil
	}

	err := c.fetchAll("/feature-flags", fetchQuery{PerPage: pp}, filters, cb)
	for i := 0; i < len(ff); i++ {
		err = c.completeFeatureFlag(&ff[i])
		if err != nil {
			return nil, err
		}
	}
	c.log("Feature flags are fetched: %v", ff)
	return ff, err
}

func (c *Client) completeFeatureFlag(ff *types.FeatureFlag) error {
	for _, id := range ff.VariationsID {
		variation, err := c.fetchVariation(id)
		if err != nil {
			continue
		}
		ff.Variations = append(ff.Variations, variation)
	}
	if ff.TargetingSegmentID > 0 {
		segment, err := c.fetchSegment(ff.TargetingSegmentID)
		if err != nil {
			return err
		}
		if segment.ID == 0 {
			return newErrNotFound("segment id")
		}
		if segment.ConditionsData == nil {
			return newErrNotFound("segment condition Data")
		}
		ff.TargetingSegment = targeting.NewSegment(segment)
	}
	return nil
}

type fetchQuery struct {
	PerPage int `url:"perPage,omitempty"`
	Page    int `url:"page,omitempty"`
}

type fetchFilter struct {
	Field      string      `json:"field"`
	Operator   string      `json:"operator"`
	Parameters interface{} `json:"parameters"`
}

func (c *Client) fetchAll(path string, q fetchQuery, filters []fetchFilter, cb respCallback) error {
	currentPage := 1
	lastPage := -1
	iterator := func(resp *fasthttp.Response, err error) error {
		if resp.StatusCode() >= fasthttp.StatusBadRequest {
			return ErrBadStatus
		}
		var cbErr error
		if cb != nil {
			cbErr = cb(resp, err)
		}
		if lastPage < 0 {
			count := resp.Header.Peek(HeaderPaginationCount)
			lastPage, err = fasthttp.ParseUint(count)
			return err
		}
		return cbErr
	}
	for {
		q.Page = currentPage
		if lastPage >= 0 && currentPage > lastPage {
			break
		}
		err := c.fetchOne(path, q, filters, iterator)
		if err != nil {
			break
		}
		currentPage++
	}
	return nil
}

func (c *Client) fetchOne(path string, q fetchQuery, filters []fetchFilter, cb respCallback) error {
	uri, err := buildFetchPath(API_URL, path, q, filters)
	if err != nil {
		return err
	}
	req := request{
		Method:      MethodGet,
		URL:         uri,
		ContentType: HeaderContentTypeJson,
	}
	c.m.Lock()
	req.AuthToken = c.token
	c.m.Unlock()
	if len(req.AuthToken) == 0 {
		return newErrCredentialsNotFound(req.String())
	}
	err = c.rest.Do(req, cb)
	if err != nil {
		c.log("Failed to fetch: %v, request: %v", err, req)
	}
	return err
}

func buildFetchPath(base, path string, q fetchQuery, filters []fetchFilter) (string, error) {
	var buf strings.Builder
	buf.WriteString(base)
	buf.WriteString(path)
	isFirst := true
	writeDelim := func() {
		if !isFirst {
			buf.WriteByte('&')
		} else {
			buf.WriteByte('?')
			isFirst = false
		}
	}
	if q.PerPage > 0 {
		writeDelim()
		buf.WriteString("perPage=")
		buf.WriteString(strconv.Itoa(q.PerPage))
	}
	if q.Page > 0 {
		writeDelim()
		buf.WriteString("page=")
		buf.WriteString(strconv.Itoa(q.Page))
	}
	if len(filters) > 0 {
		writeDelim()
		buf.WriteString("filter=")
		fbuf, err := json.Marshal(filters)
		if err != nil {
			return "", err
		}
		buf.WriteString(url.QueryEscape(string(fbuf)))
	}
	return buf.String(), nil
}
              client_test.go                                                                                      0000664 0001750 0001750 00000040776 14056132746 014504  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package kameleoon

import (
	"os"
	"testing"

	"github.com/cornelk/hashmap"
	"github.com/segmentio/encoding/json"
	"github.com/stretchr/testify/require"
	"github.com/stretchr/testify/suite"
	"github.com/valyala/fasthttp"

	"development.kameleoon.net/sdk/go-sdk/targeting"
	"development.kameleoon.net/sdk/go-sdk/types"
	"development.kameleoon.net/sdk/go-sdk/utils"
)

func TestClient(t *testing.T) {
	suite.Run(t, new(clientTestSuite))
}

func TestMockedClient(t *testing.T) {
	suite.Run(t, new(mockedTestSuite))
}

func TestTrackingClient(t *testing.T) {
	suite.Run(t, new(trackingTestSuite))
}

func TestBlockingClient(t *testing.T) {
	suite.Run(t, new(blockingTestSuite))
}

type baseTestSuite struct {
	suite.Suite
	client *Client
	siteID int
}

func (s *baseTestSuite) SetupSuite() {
	s.siteID = 21392
	cfg := &Config{}
	err := cfg.Load("testdata/client-go.yaml")
	r := s.Require()
	r.NoError(err)

	err = cfg.Load("testdata/client-go.yaml")
	r.NoError(err)
	s.client = &Client{
		Cfg:  cfg,
		rest: newRESTClient(&cfg.REST),
		Data: new(hashmap.HashMap),
	}
	err = s.client.fetchToken()
	r.NoError(err)
}

func (s *baseTestSuite) SetupTest() {
	s.client.m.Lock()
	s.client.experiments = nil
	s.client.featureFlags = nil
	s.client.Data = new(hashmap.HashMap)
	s.client.m.Unlock()
}

type clientTestSuite struct {
	baseTestSuite
}

func (s *clientTestSuite) TestRunWhenReady()  {
	r := s.Require()
	go s.client.updateConfig()
	s.client.RunWhenReady(func(c *Client, err error) {
		s.client.m.Lock()
		r.NotEmpty(s.client.experiments)
		r.NotEmpty(s.client.featureFlags)
		s.client.m.Unlock()
	})
}

func (s *clientTestSuite) TestLoadConfig() {
	cfg := &Config{}
	err := cfg.Load("testdata/client-go.yaml")
	r := s.Require()
	r.NoError(err)
	r.Equal("YOUR_CLIENT_ID", cfg.ClientID)
	r.Equal("YOUR_CLIEND_SECRET", cfg.ClientSecret)
}

func (s *clientTestSuite) TestFetchToken() {
	err := s.client.fetchToken()
	r := s.Require()
	r.NoError(err)
	r.NotEmpty(s.client.token)
}

func (s *clientTestSuite) TestFetchVariation() {
	variationID := 526061
	variation, err := s.client.fetchVariation(variationID)
	r := s.Require()
	r.NoError(err)
	r.Equal(variationID, variation.ID)
	r.Equal(s.siteID, variation.SiteID)
}

func (s *clientTestSuite) TestFetchSegment() {
	segmentID := 148586
	segment, err := s.client.fetchSegment(segmentID)
	r := s.Require()
	r.NoError(err)
	r.Equal(segmentID, segment.ID)
	r.Equal(s.siteID, segment.SiteID)
	r.NotNil(segment.ConditionsData)
	r.NotEmpty(segment.ConditionsData.FirstLevel[0].Conditions[0].Type)
	r.NotNil(segment.ConditionsData.FirstLevel[0].Conditions[0].Include)
}

func (s *clientTestSuite) TestFetchSite() {
	site, err := s.client.fetchSite()
	r := s.Require()
	r.NoError(err)
	r.NotNil(site)
	r.Equal(s.siteID, site.ID)
}

func (s *clientTestSuite) TestFetchSiteID() {
	siteId, err := s.client.fetchSiteID()
	r := s.Require()
	r.NoError(err)
	r.Equal(s.siteID, siteId)
}

func (s *clientTestSuite) TestFetchExperiment() {
	ex, err := s.client.fetchExperiments(s.siteID)
	r := s.Require()
	r.NoError(err)
	r.NotEmpty(ex)

	for _, e := range ex {
		r.Equal(s.siteID, e.SiteID)
		if e.Type != types.ExperimentTypeServerSide && e.Type != types.ExperimentTypeHybrid {
			r.Fail("incorrect experiment type", e.Type)
		}
		assertExperiment(r, e)
	}
	r.Greater(len(ex), 2)
	r.Equal(122060, ex[2].ID)
	r.Equal("Regex multiconditions", ex[2].Name)
}

func assertExperiment(r *require.Assertions, e types.Experiment) {
	if e.TargetingSegmentID > 0 {
		seg := e.TargetingSegment.(*targeting.Segment)
		r.Equal(e.TargetingSegmentID, seg.ID)
		testRecursiveTree(r, seg.Tree)
	}
	if len(e.VariationsID) > 0 {
		r.NotEmpty(e.Variations)
		r.Equal(e.VariationsID[0], e.Variations[0].ID)
	}
}

func testRecursiveTree(r *require.Assertions, t *targeting.Tree) {
	if t == nil {
		return
	}
	if t.Condition != nil {
		r.Equal(types.TargetingCustomDatum, t.Condition.GetType(), t.String())
	}
	if t.LeftTree != nil && t.RightTree != nil {
		r.NotNil(t.OrOperator)
		r.Nil(t.Condition)
	}
	testRecursiveTree(r, t.LeftTree)
	testRecursiveTree(r, t.RightTree)
}

func (s *clientTestSuite) TestFetchFeatureFlags() {
	ff, err := s.client.fetchFeatureFlags(s.siteID)
	r := s.Require()
	r.NoError(err)
	r.NotEmpty(ff)
	for _, f := range ff {
		assertFeatureFlag(r, f)
	}
}

func assertFeatureFlag(r *require.Assertions, e types.FeatureFlag) {
	if e.TargetingSegmentID > 0 {
		seg := e.TargetingSegment.(*targeting.Segment)
		r.Equal(e.TargetingSegmentID, seg.ID)
		testRecursiveTree(r, seg.Tree)
	}
	if len(e.VariationsID) > 0 {
		r.NotEmpty(e.Variations)
		r.Equal(e.VariationsID[0], e.Variations[0].ID)
	}
}

func (s *clientTestSuite) TestAddData() {
	vc := utils.GetRandomString(VisitorCodeLength)
	data := &types.CustomData{
		ID:    "777",
		Value: "test_add_data",
	}
	s.client.AddData(vc, data)
	dc := s.client.getDataCell(vc)
	r := s.Require()
	r.NotNil(dc)
	data2, ok := dc.Data[0].Data.(*types.CustomData)
	r.True(ok)
	r.Equal(data, data2)
}

func (s *clientTestSuite) TestAddDataMore() {
	vc := utils.GetRandomString(VisitorCodeLength)
	data := &types.CustomData{
		ID:    "777",
		Value: "test_add_data1",
	}
	s.client.AddData(vc, data)

	data2 := &types.CustomData{
		ID:    "777",
		Value: "test_add_data2",
	}
	s.client.AddData(vc, data2)
	dc := s.client.getDataCell(vc)

	r := s.Require()
	r.NotNil(dc)
	data3, ok := dc.Data[0].Data.(*types.CustomData)
	r.True(ok)
	r.Equal(data, data3)
	data4, ok := dc.Data[1].Data.(*types.CustomData)
	r.True(ok)
	r.Equal(data2, data4)
}

func (s *clientTestSuite) TestGetVariationData() {
	ex, err := s.client.fetchExperiments(s.siteID)
	r := s.Require()
	r.NotEmpty(ex)

	s.client.m.Lock()
	s.client.experiments = append(s.client.experiments, ex...)
	s.client.m.Unlock()

	var data []byte
	if err != nil {
		errNF := &ErrVariationNotFound{}
		r.ErrorAs(err, &errNF)
		data, err = s.client.GetVariationAssociatedData(1234)
		r.NoError(err)
	}

	data, err = s.client.GetVariationAssociatedData(550105)
	r.NoError(err)
	r.NotNil(data)

	value := make(map[string]string)
	err = json.Unmarshal(data, &value)
	r.NoError(err)
	r.Equal("variation2", value["test"])
}

func (s *clientTestSuite) TestGetFeatureVariable() {
	ff, err := s.client.fetchFeatureFlags(s.siteID)
	r := s.Require()
	r.NotEmpty(ff)
	s.client.m.Lock()
	s.client.featureFlags = append(s.client.featureFlags, ff...)
	s.client.m.Unlock()
	var fv interface{}
	if err != nil {
		errConfNF := &ErrFeatureConfigNotFound{}
		r.ErrorAs(err, &errConfNF)
		fv, err = s.client.GetFeatureVariable("wrong", "kameleoon")
		if err != nil {
			errVarNF := &ErrFeatureVariableNotFound{}
			r.ErrorAs(err, &errVarNF)
			fv, err = s.client.GetFeatureVariable("test-sdk", "wrong")
		}
	}
	fv, err = s.client.GetFeatureVariable("test-sdk", "kameleoon")
	r.NotNil(fv)
	r.Equal("found", fv.(map[string]interface{})["value"])
}

func loadFileJson(path string, i interface{}) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	return json.NewDecoder(file).Decode(i)
}

type mockRestClient struct {
	*rest
	response func(resp *fasthttp.Response) (*fasthttp.Response, error)
}

func (c *mockRestClient) Do(r request, callback respCallback) error {
	if c.response == nil {
		return nil
	}
	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseResponse(resp)
	response, err := c.response(resp)
	if callback == nil {
		callback = defaultRespCallback
	}
	return callback(response, err)
}

type mockTestSuite struct {
	baseTestSuite
}

func (s *mockTestSuite) SetupSuite() {
	s.baseTestSuite.SetupSuite()
	m := new(mockRestClient)
	m.rest = s.client.rest.(*rest)
	s.client.rest = m
}

func (s *mockTestSuite) SetupTest() {
	s.baseTestSuite.SetupTest()
	s.client.rest.(*mockRestClient).response = nil
}

type mockedTestSuite struct {
	mockTestSuite
}

func (s *mockedTestSuite) TestActivateFeature() {
	r := s.Require()
	id := 777
	seg := &types.Segment{}
	err := loadFileJson("testdata/segments/segment0.json", seg)
	r.NoError(err)
	segment := targeting.NewSegment(seg)
	ff := types.FeatureFlag{
		ID:               id,
		TargetingSegment: segment,
		ExpositionRate:   0.7,
		VariationsID:     []int{50342},
	}
	s.client.m.Lock()
	s.client.featureFlags = append(s.client.featureFlags, ff)
	s.client.m.Unlock()

	visitorCode := "test_kameleoon_visitor_code"
	data := &types.CustomData{
		ID:    "1",
		Value: "test_1",
	}
	s.client.AddData(visitorCode, data)
	active, err := s.client.ActivateFeature(visitorCode, id)
	r.NoError(err)
	r.True(active)

	s.client.m.Lock()
	s.client.featureFlags[0].TargetingSegment = nil
	s.client.m.Unlock()
	active, err = s.client.ActivateFeature(visitorCode, id)
	r.NoError(err)
	r.True(active)
}

func (s *mockedTestSuite) TestTriggerExperiment() {
	r := s.Require()
	exID := 777
	seg := &types.Segment{}
	err := loadFileJson("testdata/segments/segment0.json", seg)
	r.NoError(err)
	segment := targeting.NewSegment(seg)
	dev := types.Deviations{
		"1": 0.45,
		"2": 0.25,
		"3": 0.25,
	}
	ex := types.Experiment{
		ID:               exID,
		TargetingSegment: segment,
		Deviations:       dev,
	}
	s.client.m.Lock()
	s.client.experiments = append(s.client.experiments, ex)
	s.client.m.Unlock()

	vc := utils.GetRandomString(VisitorCodeLength)
	data := &types.CustomData{
		ID:    "1",
		Value: "test_1",
	}
	s.client.AddData(vc, data)
	varId, err := s.client.TriggerExperiment(vc, exID)
	r.NoError(err)
	switch utils.WriteUint(varId) {
	case "1", "2", "3":
	default:
		r.Fail("variation id not in deviations: ", varId)
	}
	s.client.m.Lock()
	s.client.experiments[0].TargetingSegment = nil
	s.client.m.Unlock()

	varId, err = s.client.TriggerExperiment(vc, exID)
	r.NoError(err)
	switch utils.WriteUint(varId) {
	case "1", "2", "3":
	default:
		r.Fail("variation id not in deviations: ", varId)
	}
}

func (s *mockedTestSuite) TestRepartition() {
	exID := 777
	seg := &types.Segment{}
	err := loadFileJson("testdata/segments/segment0.json", seg)
	if err != nil {
		return
	}
	segment := targeting.NewSegment(seg)
	dev := types.Deviations{
		"1": 0.45,
		"2": 0.25,
		"3": 0.25,
	}
	devSum := 0.95
	ex := types.Experiment{
		ID:               exID,
		TargetingSegment: segment,
		Deviations:       dev,
	}
	s.client.m.Lock()
	s.client.experiments = append(s.client.experiments, ex)
	s.client.m.Unlock()

	repartitions := types.Deviations{
		"1":      0,
		"2":      0,
		"3":      0,
		"origin": 0,
	}
	var varId int
	for i := 0; i < 10000; i++ {
		vc := utils.GetRandomString(VisitorCodeLength)
		data := &types.CustomData{
			ID:    "1",
			Value: "test_1",
		}
		s.client.AddData(vc, data)
		varId, err = s.client.TriggerExperiment(vc, exID)
		if err != nil {
			repartitions["origin"]++
		} else {
			repartitions[utils.WriteUint(varId)]++
		}
	}
	r := s.Require()
	for k, v := range repartitions {
		if k == "origin" {
			r.InEpsilon(1-devSum, v/10000.0, 0.1)
		} else {
			r.InEpsilon(dev[k], v/10000.0, 0.1)
		}
	}
}

type trackingTestSuite struct {
	mockTestSuite
}

func (s *trackingTestSuite) TestFlushVisitor() {
	s.client.rest.(*mockRestClient).response = func(resp *fasthttp.Response) (*fasthttp.Response, error) {
		resp.SetStatusCode(fasthttp.StatusOK)
		return resp, nil
	}
	visitorCode := "test-kameleoon"
	s.client.AddData(visitorCode, &types.CustomData{
		ID:    "1",
		Value: "test",
	})
	s.client.postTrackingAsync(trackingRequest{
		Type:        TrackingRequestData,
		VisitorCode: visitorCode,
	})
	r := s.Require()
	for kv := range s.client.Data.Iter() {
		if dc, ok := kv.Value.(*types.DataCell); ok {
			r.Equal(len(dc.Data), len(dc.Index))
		}
	}

	s.client.AddData(visitorCode, &types.CustomData{
		ID:    "2",
		Value: "test_without_visitor_code",
	})
	s.client.postTrackingAsync(trackingRequest{
		Type: TrackingRequestData,
	})
	for kv := range s.client.Data.Iter() {
		if dc, ok := kv.Value.(*types.DataCell); ok {
			r.Equal(len(dc.Data), len(dc.Index))
		}
	}
}

func (s *trackingTestSuite) TestFlushAll() {
	s.client.rest.(*mockRestClient).response = func(resp *fasthttp.Response) (*fasthttp.Response, error) {
		resp.SetStatusCode(fasthttp.StatusOK)
		return resp, nil
	}
	visitorCode := "test-code"
	s.client.AddData(visitorCode, &types.CustomData{
		ID:    "test-id",
		Value: "test-value",
	})
	s.client.AddData(visitorCode, &types.Browser{
		Type: types.BrowserTypeChrome,
	})
	s.client.AddData(visitorCode, &types.PageView{
		URL:   "www.test.com",
		Title: "test-title",
	})
	s.client.AddData(visitorCode, &types.Conversion{
		GoalID:  1,
		Revenue: 100,
	})
	s.client.AddData(visitorCode, &types.Interest{
		Index: 1,
	})
	s.client.postTrackingAsync(trackingRequest{
		Type:        TrackingRequestData,
		VisitorCode: visitorCode,
	})
	r := s.Require()
	for kv := range s.client.Data.Iter() {
		if dc, ok := kv.Value.(*types.DataCell); ok {
			r.Equal(len(dc.Data), len(dc.Index))
		}
	}
}

func (s *trackingTestSuite) TestFlushError() {
	s.client.rest.(*mockRestClient).response = func(resp *fasthttp.Response) (*fasthttp.Response, error) {
		resp.SetStatusCode(fasthttp.StatusInternalServerError)
		resp.SetBodyString("Internal Server Error")
		return resp, nil
	}
	visitorCode := "test-kameleoon"

	s.client.AddData(visitorCode, &types.Conversion{
		GoalID:  1,
		Revenue: 100.1,
	})
	s.client.postTrackingAsync(trackingRequest{
		Type:        TrackingRequestData,
		VisitorCode: visitorCode,
	})
	for kv := range s.client.Data.Iter() {
		if dc, ok := kv.Value.(*types.DataCell); ok {
			s.Require().Empty(dc.Index)
		}
	}
}

type blockingTestSuite struct {
	mockTestSuite
}

func (s *blockingTestSuite) SetupSuite() {
	s.mockTestSuite.SetupSuite()
	s.client.Cfg.BlockingMode = true
}

func (s *blockingTestSuite) TestTriggerExperimentBlocking() {
	s.client.rest.(*mockRestClient).response = func(resp *fasthttp.Response) (*fasthttp.Response, error) {
		resp.SetStatusCode(fasthttp.StatusOK)
		resp.SetBodyString("1")
		return resp, nil
	}
	r := s.Require()
	exID := 777
	seg := &types.Segment{}
	err := loadFileJson("testdata/segments/segment0.json", seg)
	r.NoError(err)
	segment := targeting.NewSegment(seg)
	dev := types.Deviations{
		"1": 1.0,
	}
	ex := types.Experiment{
		ID:               exID,
		TargetingSegment: segment,
		Deviations:       dev,
	}
	s.client.m.Lock()
	s.client.experiments = append(s.client.experiments, ex)
	s.client.m.Unlock()

	vc := utils.GetRandomString(VisitorCodeLength)
	data := &types.CustomData{
		ID:    "1",
		Value: "test_1",
	}
	s.client.AddData(vc, data)
	varId, err := s.client.TriggerExperiment(vc, exID)
	r.NoError(err)
	r.Equal(1, varId)
}

func (s *blockingTestSuite) TestTriggerExperimentTimeout() {
	s.client.rest.(*mockRestClient).response = func(resp *fasthttp.Response) (*fasthttp.Response, error) {
		resp.SetStatusCode(fasthttp.StatusOK)
		return resp, fasthttp.ErrTimeout
	}
	r := s.Require()
	exID := 777
	seg := &types.Segment{}
	err := loadFileJson("testdata/segments/segment0.json", seg)
	r.NoError(err)
	segment := targeting.NewSegment(seg)
	dev := types.Deviations{
		"1": 1.0,
	}
	ex := types.Experiment{
		ID:               exID,
		TargetingSegment: segment,
		Deviations:       dev,
	}
	s.client.m.Lock()
	s.client.experiments = append(s.client.experiments, ex)
	s.client.m.Unlock()

	vc := utils.GetRandomString(VisitorCodeLength)
	data := &types.CustomData{
		ID:    "1",
		Value: "test_1",
	}
	s.client.AddData(vc, data)
	_, err = s.client.TriggerExperiment(vc, exID)
	r.ErrorIs(err, fasthttp.ErrTimeout)
}

func (s *blockingTestSuite) TestActivateFeatureFlag() {
	s.client.rest.(*mockRestClient).response = func(resp *fasthttp.Response) (*fasthttp.Response, error) {
		resp.SetStatusCode(fasthttp.StatusOK)
		return resp, nil
	}
	r := s.Require()
	id := 777
	seg := &types.Segment{}
	err := loadFileJson("testdata/segments/segment0.json", seg)
	r.NoError(err)
	segment := targeting.NewSegment(seg)
	ff := types.FeatureFlag{
		ID:               id,
		TargetingSegment: segment,
		ExpositionRate:   0.7,
	}
	s.client.m.Lock()
	s.client.featureFlags = append(s.client.featureFlags, ff)
	s.client.m.Unlock()

	active, err := s.client.ActivateFeature("test_kameleoon_visitor_code", id)
	r.Error(err)
	r.False(active)
}

func (s *blockingTestSuite) TestActivateFeatureFlagTimeout() {
	s.client.rest.(*mockRestClient).response = func(resp *fasthttp.Response) (*fasthttp.Response, error) {
		resp.SetStatusCode(fasthttp.StatusOK)
		return resp, fasthttp.ErrTimeout
	}
	r := s.Require()
	id := 777
	seg := &types.Segment{}
	err := loadFileJson("testdata/segments/segment0.json", seg)
	r.NoError(err)
	segment := targeting.NewSegment(seg)
	ff := types.FeatureFlag{
		ID:               id,
		TargetingSegment: segment,
		ExpositionRate:   0.7,
	}
	s.client.m.Lock()
	s.client.featureFlags = append(s.client.featureFlags, ff)
	s.client.m.Unlock()

	active, err := s.client.ActivateFeature("test_kameleoon_visitor_code", id)
	r.ErrorIs(err, fasthttp.ErrTimeout)
	r.False(active)
}
  config.go                                                                                           0000664 0001750 0001750 00000006674 14056132746 013433  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package kameleoon

import (
	"strings"
	"time"

	"github.com/cristalhq/aconfig"
	"github.com/cristalhq/aconfig/aconfigyaml"
)

const (
	DefaultConfigPath           = "/etc/kameleoon/client-go.yaml"
	DefaultConfigUpdateInterval = time.Hour
	DefaultRequestTimeout       = 2 * time.Second
	DefaultVisitorDataMaxSize   = 500 // 500 mb
	DefaultTrackingVersion      = "sdk/go/2.0.1"
	UserAgent                   = "kameleoon-client-go/"
)

type Config struct {
	REST                 RestConfig
	Logger               Logger        `yml:"-" yaml:"-"`
	SiteCode             string        `yml:"site_code" yaml:"site_code"`
	TrackingURL          string        `yml:"tracking_url" yaml:"tracking_url" default:"https://api-ssx.kameleoon.com"`
	TrackingVersion      string        `yml:"tracking_version" yaml:"tracking_version"`
	ProxyURL             string        `yml:"proxy_url" yaml:"proxy_url"`
	ClientID             string        `yml:"client_id" yaml:"client_id"`
	ClientSecret         string        `yml:"client_secret" yaml:"client_secret"`
	Version              string        `yml:"version" yaml:"version"`
	ConfigUpdateInterval time.Duration `yml:"config_update_interval" yaml:"config_update_interval" default:"1h"`
	Timeout              time.Duration `yml:"timeout" yaml:"timeout" default:"2s"`
	VisitorDataMaxSize   int           `yml:"visitor_data_max_size" yaml:"visitor_data_max_size"`
	BlockingMode         bool          `yml:"blocking_mode" yaml:"blocking_mode"`
	VerboseMode          bool          `yml:"verbose_mode" yaml:"verbose_mode"`
}

func LoadConfig(path string) (*Config, error) {
	c := &Config{}
	return c, c.Load(path)
}

func (c *Config) defaults() {
	if c.Logger == nil {
		c.Logger = defaultLogger
	}
	if len(c.TrackingURL) == 0 {
		c.TrackingURL = API_SSX_URL
	}
	if c.ConfigUpdateInterval == 0 {
		c.ConfigUpdateInterval = DefaultConfigUpdateInterval
	}
	if c.Timeout == 0 {
		c.Timeout = DefaultRequestTimeout
	}
	if c.VisitorDataMaxSize == 0 {
		c.VisitorDataMaxSize = DefaultVisitorDataMaxSize
	}
	if len(c.Version) == 0 {
		c.Version = sdkVersion
	}
	if len(c.TrackingVersion) == 0 {
		c.TrackingVersion = DefaultTrackingVersion
	}
	c.REST.defaults(c.Version)
}

func (c *Config) Load(path string) error {
	if len(path) == 0 {
		path = DefaultConfigPath
	}
	err := c.loadFile(path)
	c.defaults()
	return err
}

func (c *Config) loadFile(configPath string) error {
	yml := aconfigyaml.New()
	loader := aconfig.LoaderFor(c, aconfig.Config{
		SkipFlags:          true,
		SkipEnv:            true,
		FailOnFileNotFound: true,
		AllowUnknownFields: true,
		Files:              []string{configPath},
		FileDecoders: map[string]aconfig.FileDecoder{
			".yaml": yml,
			".yml":  yml,
		},
	})

	return loader.Load()
}

const (
	DefaultReadTimeout     = 5 * time.Second
	DefaultWriteTimeout    = 5 * time.Second
	DefaultDoTimeout       = 10 * time.Second
	DefaultMaxConnsPerHost = 10000
)

type RestConfig struct {
	ProxyURL        string
	UserAgent       string
	DoTimeout       time.Duration
	ReadTimeout     time.Duration
	WriteTimeout    time.Duration
	MaxConnsPerHost int
}

func (c *RestConfig) defaults(version string) {
	var b strings.Builder
	b.WriteString(UserAgent)
	b.WriteString(version)
	c.UserAgent = b.String()

	if c.ReadTimeout == 0 {
		c.ReadTimeout = DefaultReadTimeout
	}
	if c.WriteTimeout == 0 {
		c.WriteTimeout = DefaultWriteTimeout
	}
	if c.DoTimeout == 0 {
		c.DoTimeout = DefaultDoTimeout
	}
	if c.MaxConnsPerHost == 0 {
		c.MaxConnsPerHost = DefaultMaxConnsPerHost
	}
}
                                                                    config_test.go                                                                                      0000664 0001750 0001750 00000002163 14056132746 014457  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package kameleoon

import (
	"github.com/stretchr/testify/assert"
	"testing"
	"time"
)

func TestConfig_Load(t *testing.T) {
	ex := &Config{
		REST: RestConfig{
			ProxyURL:        "",
			UserAgent:       "kameleoon-client-go/1.0.0",
			DoTimeout:       DefaultDoTimeout,
			ReadTimeout:     DefaultReadTimeout,
			WriteTimeout:    DefaultWriteTimeout,
			MaxConnsPerHost: DefaultMaxConnsPerHost,
		},
		Logger:               defaultLogger,
		SiteCode:             "nfv42afnay",
		TrackingURL:          API_SSX_URL,
		TrackingVersion:      DefaultTrackingVersion,
		ProxyURL:             "",
		ClientID:             "YOUR_CLIENT_ID",
		ClientSecret:         "YOUR_CLIENT_SECRET",
		Version:              "1.0.0",
		ConfigUpdateInterval: 5 * time.Minute,
		Timeout:              time.Second,
		VisitorDataMaxSize:   500,
		BlockingMode:         false,
		VerboseMode:          true,
	}
	path := "testdata/client-go.yaml"
	t.Run("load config", func(t *testing.T) {
		ac := &Config{}
		if err := ac.Load(path); err != nil {
			t.Errorf("config.Load() error = %v", err)
		}
		assert.Equal(t, ex, ac)
	})

}
                                                                                                                                                                                                                                                                                                                                                                                                             cookie.go                                                                                           0000664 0001750 0001750 00000006651 14056132746 013432  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package kameleoon

import (
	"crypto/sha256"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/valyala/fasthttp"

	"development.kameleoon.net/sdk/go-sdk/types"
	"development.kameleoon.net/sdk/go-sdk/utils"
)

type Cookie struct {
	defaultVisitorCode string
}

const (
	VisitorCodeLength = 16
	CookieKeyJs       = "_js_"
	CookieName        = "kameleoonVisitorCode"
	CookieExpireTime  = 380 * 24 * time.Hour
)

// GetVisitorCode should be called to get the Kameleoon visitorCode for the current visitor.
//
// This is especially important when using Kameleoon in a mixed front-end and back-end environment,
// where user identification consistency must be guaranteed.
//
// The implementation logic is described here:
// First we check if a kameleoonVisitorCode cookie or query parameter associated with the current HTTP request can be
// found. If so, we will use this as the visitor identifier. If no cookie / parameter is found in the current
// request, we either randomly generate a new identifier, or use the defaultVisitorCode argument as identifier if it
// is passed. This allows our customers to use their own identifiers as visitor codes, should they wish to.
// This can have the added benefit of matching Kameleoon visitors with their own users without any additional
// look-ups in a matching table.
func (c *Client) GetVisitorCode(req *fasthttp.Request, defaultVisitorCode ...string) string {
	visitorCode := readVisitorCode(req)
	if len(visitorCode) == 0 {
		if len(defaultVisitorCode) > 0 {
			visitorCode = defaultVisitorCode[0]
		} else {
			visitorCode = utils.GetRandomString(VisitorCodeLength)
		}
	}
	return visitorCode
}

// SetVisitorCode should be called to set the Kameleoon visitorCode in response cookie.
//
// The server-side (via HTTP header) kameleoonVisitorCode cookie is set with the value.
func (c *Client) SetVisitorCode(resp *fasthttp.Response, visitorCode, domain string) {
	cookie := newVisitorCodeCookie(visitorCode, domain)
	resp.Header.SetCookie(cookie)
	fasthttp.ReleaseCookie(cookie)
}

func (c *Client) ObtainVisitorCode(req *fasthttp.Request, resp *fasthttp.Response, domain string, defaultVisitorCode ...string) string {
	visitorCode := c.GetVisitorCode(req, defaultVisitorCode...)
	c.SetVisitorCode(resp, visitorCode, domain)
	return visitorCode
}

func readVisitorCode(req *fasthttp.Request) string {
	cookie := string(req.Header.Cookie(CookieName))
	if strings.HasPrefix(cookie, CookieKeyJs) {
		cookie = cookie[len(CookieKeyJs):]
	}
	if len(cookie) < VisitorCodeLength {
		return ""
	}
	return cookie[:VisitorCodeLength]
}

func newVisitorCodeCookie(visitorCode, domain string) *fasthttp.Cookie {
	c := fasthttp.AcquireCookie()
	c.SetKey(CookieName)
	c.SetValue(visitorCode)
	c.SetExpire(time.Now().Add(CookieExpireTime))
	c.SetPath("/")
	c.SetDomain(domain)
	return c
}

func getHashDouble(containerID int, visitorCode string, respoolTime types.RespoolTime) float64 {
	var b []byte
	b = append(b, visitorCode...)
	b = append(b, utils.WriteUint(containerID)...)

	vals := make([]float64, len(respoolTime))
	i := 0
	for _, v := range respoolTime {
		vals[i] = v
		i++
	}
	sort.Float64s(vals)
	for _, v := range vals {
		b = append(b, strconv.FormatFloat(v, 'f', -1, 64)...)
	}

	h := sha256.New()
	h.Write(b)

	z := new(big.Int).SetBytes(h.Sum(nil))
	n1 := new(big.Int).Exp(big.NewInt(2), big.NewInt(256), nil)

	f1 := new(big.Float).SetInt(z)
	f2 := new(big.Float).SetInt(n1)
	f, _ := new(big.Float).Quo(f1, f2).Float64()
	return f
}
                                                                                       cookie_test.go                                                                                      0000664 0001750 0001750 00000005467 14056132746 014475  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package kameleoon

import (
	"development.kameleoon.net/sdk/go-sdk/types"
	"github.com/stretchr/testify/suite"
	"github.com/valyala/fasthttp"
	"testing"

	"development.kameleoon.net/sdk/go-sdk/utils"
)

func TestCookieClient(t *testing.T) {
	suite.Run(t, new(cookieTestSuite))
}

type cookieTestSuite struct {
	baseTestSuite
}

func (s *cookieTestSuite) TestObtainVisitorCode()  {
	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)
	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseResponse(resp)

	vc := s.client.ObtainVisitorCode(req, resp, "test.com")
	r := s.Require()
	r.Regexp(`^([a-z0-9]){16}$`, vc)

	c := fasthttp.AcquireCookie()
	defer fasthttp.ReleaseCookie(c)
	err := c.ParseBytes(resp.Header.PeekCookie(CookieName))
	r.NoError(err)
	r.Equal(vc, string(c.Value()))
	r.Equal("/", string(c.Path()))
}

func (s *cookieTestSuite) TestGetVisitorCode() {
	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)

	visitorCode := utils.GetRandomString(VisitorCodeLength)

	c := newVisitorCodeCookie(visitorCode, "test.com")
	raw := c.AppendBytes(nil)
	req.Header.SetCookieBytesKV([]byte(CookieName), raw[len(CookieName)+1:])

	vc := s.client.GetVisitorCode(req)
	r := s.Require()
	r.Regexp(`^([a-z0-9]){16}$`, vc)
	r.Equal(visitorCode, vc)
}

func (s *cookieTestSuite) TestGetVisitorCodeRandom() {
	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)
	vc := s.client.GetVisitorCode(req)
	s.Require().Regexp(`^([a-z0-9]){16}$`, vc)
}

func (s *cookieTestSuite) TestGetVisitorCodeDefault() {
	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)
	defaultVisitorCode := "1234abcd4321"
	vc := s.client.GetVisitorCode(req, defaultVisitorCode)
	s.Require().Equal(defaultVisitorCode, vc)
}

func (s *cookieTestSuite) TestSetVisitorCode() {
	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseResponse(resp)

	visitorCode := utils.GetRandomString(VisitorCodeLength)

	s.client.SetVisitorCode(resp, visitorCode, "test.com")

	c := fasthttp.AcquireCookie()
	defer fasthttp.ReleaseCookie(c)
	err := c.ParseBytes(resp.Header.PeekCookie(CookieName))
	r := s.Require()
	r.NoError(err)
	r.Equal(visitorCode, string(c.Value()))
	r.Equal("/", string(c.Path()))

	c.SetValue(CookieKeyJs + visitorCode + "_WRONG_END")
	c.SetDomain(".kameleoon.net")
	raw := c.AppendBytes(nil)

	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)
	req.Header.SetCookieBytesKV([]byte(CookieName), raw[len(CookieName)+1:])

	vc := s.client.GetVisitorCode(req)
	r.Equal(visitorCode, vc)
}

func (s *cookieTestSuite) TestGetHashDouble() {
	value := getHashDouble(1, "test", types.RespoolTime{
		"2": 12012,
		"1": 12013,
	})
	s.Require().Equal(0.2846913760164173, value)
	value = getHashDouble(109105, "kameleoon", types.RespoolTime{
		"1": 28,
		"0": 77,
	})
	s.Require().Equal(0.6269555701905331, value)
}
                                                                                                                                                                                                         deploy.sh                                                                                           0000775 0001750 0001750 00000000131 14056134332 013441  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              #!/bin/sh
# deploy - push selected files to github

rm -rf deploy
tar cvf * ./deploy.tar
                                                                                                                                                                                                                                                                                                                                                                                                                                       errors.go                                                                                           0000664 0001750 0001750 00000005070 14056132746 013467  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package kameleoon

import "errors"

var (
	ErrInvalidFeatureKeyType = errors.New("feature key should be a string or an int")
	ErrBadStatus             = errors.New("bad status code")
	ErrEmptyResponse         = errors.New("empty response")
)

// APIError is the base type for endpoint-specific errors.
type APIError struct {
	Message string `json:"message"`
}

func (e APIError) Error() string {
	return e.Message
}

func (e APIError) IsApiError() bool {
	return true
}

type ErrNotFound struct {
	APIError
}

func (e ErrNotFound) IsNotFoundError() bool {
	return true
}

func (e ErrNotFound) Error() string {
	return e.Message + " not found"
}

type ErrVariationNotFound struct {
	ErrNotFound
}

func newErrVariationNotFound(msg string) error {
	return &ErrVariationNotFound{ErrNotFound{APIError{Message: msg}}}
}

func (e ErrVariationNotFound) Error() string {
	return "variation " + e.ErrNotFound.Error()
}

type ErrExperimentConfigNotFound struct {
	ErrNotFound
}

func newErrExperimentConfigNotFound(msg string) error {
	return &ErrExperimentConfigNotFound{ErrNotFound{APIError{Message: msg}}}
}

func (e ErrExperimentConfigNotFound) Error() string {
	return "experiment " + e.ErrNotFound.Error()
}

type ErrFeatureConfigNotFound struct {
	ErrNotFound
}

func newErrFeatureConfigNotFound(msg string) error {
	return &ErrFeatureConfigNotFound{ErrNotFound{APIError{Message: msg}}}
}

func (e ErrFeatureConfigNotFound) Error() string {
	return "feature flag " + e.ErrNotFound.Error()
}

type ErrFeatureVariableNotFound struct {
	ErrNotFound
}

func newErrNotFound(msg string) error {
	return &ErrNotFound{APIError{Message: msg}}
}

func newErrFeatureVariableNotFound(msg string) error {
	return &ErrFeatureVariableNotFound{ErrNotFound{APIError{Message: msg}}}
}

func (e ErrFeatureVariableNotFound) Error() string {
	return "feature variable " + e.ErrNotFound.Error()
}

type ErrCredentialsNotFound struct {
	ErrNotFound
}

func newErrCredentialsNotFound(msg string) error {
	return &ErrCredentialsNotFound{ErrNotFound{APIError{Message: msg}}}
}

func (e ErrCredentialsNotFound) Error() string {
	return "credentials " + e.ErrNotFound.Error()
}

type ErrNotTargeted struct {
	APIError
}

func newErrNotTargeted(msg string) error {
	return &ErrNotTargeted{APIError{Message: msg}}
}

func (e ErrNotTargeted) Error() string {
	return "visitor " + e.Message + " is not targeted"
}

type ErrNotActivated struct {
	APIError
}

func newErrNotActivated(msg string) error {
	return &ErrNotActivated{APIError{Message: msg}}
}

func (e ErrNotActivated) Error() string {
	return "visitor " + e.Message + " is not activated"
}
                                                                                                                                                                                                                                                                                                                                                                                                                                                                        example_test.go                                                                                     0000664 0001750 0001750 00000016051 14056132746 014646  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package kameleoon_test

import (
	"encoding/json"
	"log"
	"os"
	"time"

	"github.com/valyala/fasthttp"

	kameleoon "development.kameleoon.net/sdk/go-sdk"
	"development.kameleoon.net/sdk/go-sdk/types"
)

const SiteCode = "a8st4f59bj"

func Example() {
	// Make config on place
	config := &kameleoon.Config{
		REST: kameleoon.RestConfig{
			ProxyURL:        "http://proxy-pass:1234/", // Sets from config.ProxyURL
			UserAgent:       "kameleoon-client-go/",    // Builds with version from config.Version
			DoTimeout:       10 * time.Second,
			ReadTimeout:     5 * time.Second,
			WriteTimeout:    5 * time.Second,
			MaxConnsPerHost: 10000,
		},
		Logger:               log.New(os.Stderr, "", log.LstdFlags), // Log interface (log.Printf)
		SiteCode:             "",                                    // Required
		TrackingURL:          "https://api-ssx.kameleoon.com",
		ProxyURL:             "http://proxy-pass:1234/",
		ClientID:             "", // Required
		ClientSecret:         "", // Required
		Version:              "1.0.0",
		ConfigUpdateInterval: time.Hour,
		Timeout:              2 * time.Second,
		VisitorDataMaxSize:   500,
		BlockingMode:         false,
		VerboseMode:          false,
	}

	// Or load from file
	//config, err := kameleoon.LoadConfig("/etc/kameleoon/client-go.yaml")
	//config.SiteCode = SiteCode

	// Load or reload config from file with existed struct
	//config.Load("/etc/kameleoon/client-go.yaml")

	// Create new client
	// Client will start fetching all available experiments and feature flags in background
	// And periodically updates in a specified interval
	client := kameleoon.NewClient(config)

	// Get *fasthttp.Request from the server or make it own
	req := fasthttp.AcquireRequest()
	// Set kameleoonVisitorCode cookie manually or leave it blank
	req.Header.SetCookie(kameleoon.CookieName, "1234567890cookie")

	// Acquire visitor code from request
	// If kameleoonVisitorCode cookie is empty, function will return a new visitor code
	visitorCode := client.GetVisitorCode(req)

	// Or provide a default visitor code to avoid generating a new one
	//visitorCode := client.GetVisitorCode(req, "defaultCode12345")

	// Acquire *fasthttp.Response for writing responses to client
	resp := fasthttp.AcquireResponse()
	// Set visitor code to response cookies
	client.SetVisitorCode(resp, visitorCode, "example.com")
	// Or use ObtainVisitorCode for getting visitor code from request and setting it to response cookies
	//visitorCode := client.ObtainVisitorCode(req, resp, "example.com")

	// Triggering an experiment
	experimentID := 75253
	variationID, err := client.TriggerExperiment(visitorCode, experimentID)
	if err != nil {
		switch err.(type) {
		case *kameleoon.ErrNotTargeted:
			// The user did not trigger the experiment, as the associated targeting segment
			// conditions were not fulfilled. He should see the reference variation
			variationID = 0
		case *kameleoon.ErrNotActivated:
			// The user triggered the experiment, but did not activate it.
			// Usually, this happens because the user has been associated with excluded traffic
			variationID = 0
		case *kameleoon.ErrExperimentConfigNotFound:
			// The user will not be counted into the experiment, but should see the reference variation
			variationID = 0
		default:
			// Handle unexpected errors
			panic(err)
		}
	}

	// Implementing variation code
	var recommendedProductsNumber int
	switch variationID {
	case 0:
		// This is the default / reference number of products to display
		recommendedProductsNumber = 5
	case 148382:
		// We are changing number of recommended products for this variation to 10
		recommendedProductsNumber = 10
	case 187791:
		// We are changing number of recommended products for this variation to 8
		recommendedProductsNumber = 8
	}
	// Here you should have code to generate the HTML page back to the client,
	// where recommendedProductsNumber will be used
	renderFn(recommendedProductsNumber)

	// Tracking conversion
	goalID := 83023
	client.TrackConversion(visitorCode, goalID)

	// Activate feature flag
	featureKey := "new_checkout"
	hasNewCheckout, err := client.ActivateFeature(visitorCode, featureKey)
	if err != nil {
		switch err.(type) {
		case *kameleoon.ErrNotTargeted:
			// The user did not trigger the feature, as the associated targeting segment conditions were not fulfilled.
			// The feature should be considered inactive
			hasNewCheckout = false
		case *kameleoon.ErrFeatureConfigNotFound:
			// The user will not be counted into the experiment, but should see the reference variation
			hasNewCheckout = false
		default:
			// Handle unexpected errors
			panic(err)
		}
	}
	if hasNewCheckout {
		// Implement new checkout code here
	}

	// Obtain variation associated data
	experimentID = 75253
	variationID, err = client.TriggerExperiment(visitorCode, experimentID)
	if err != nil {
		// Handle errors
		panic(err)
	}

	// Raw byte slice response (json)
	bytes, err := client.GetVariationAssociatedData(variationID)
	if err != nil {
		switch err.(type) {
		case *kameleoon.ErrVariationNotFound:
			// The variation is not yet activated on Kameleoon's side,
			// ie the associated experiment is not online
		default:
			// Handle unexpected errors
			panic(err)
		}
	}
	data := make(map[string]string)
	if err = json.Unmarshal(bytes, &data); err != nil {
		// Handle errors
		panic(err)
	}
	//firstName := data["firstName"]

	// Get feature variable
	featureKey = "myFeature"
	variableKey := "myVariable"
	customData, err := client.GetFeatureVariable(featureKey, variableKey)
	if err != nil {
		switch err.(type) {
		case *kameleoon.ErrFeatureConfigNotFound:
			// The feature is not yet activated on Kameleoon's side
		case *kameleoon.ErrFeatureVariableNotFound:
			// The feature variable not found in customJson field
		default:
			// Handle unexpected errors
			panic(err)
		}
	}
	if _, ok := customData.(string); ok {
	}

	// Track conversion
	goalID = 83023
	client.AddData(visitorCode, &types.Browser{Type: types.BrowserTypeChrome})

	client.AddData(visitorCode,
		&types.PageView{
			URL:      "https://url.com",
			Title:    "title",
			Referrer: 3,
		},
		&types.Interest{Index: 2},
	)
	client.AddData(visitorCode, &types.Conversion{
		GoalID:   32,
		Revenue:  10,
		Negative: false,
	})
	client.TrackConversion(visitorCode, goalID)

	// Add data
	client.AddData(visitorCode, &types.Browser{Type: types.BrowserTypeChrome})
	client.AddData(visitorCode,
		&types.PageView{
			URL:      "https://url.com",
			Title:    "title",
			Referrer: 3,
		},
		&types.Interest{Index: 0},
	)
	client.AddData(visitorCode, &types.Conversion{
		GoalID:   32,
		Revenue:  10,
		Negative: false,
	})

	// Flush
	client.AddData(visitorCode, &types.Browser{Type: types.BrowserTypeChrome})
	client.AddData(visitorCode,
		&types.PageView{
			URL:      "https://url.com",
			Title:    "title",
			Referrer: 3,
		},
		&types.Interest{Index: 0},
	)
	client.AddData(visitorCode, &types.Conversion{
		GoalID:   32,
		Revenue:  10,
		Negative: false,
	})
	client.AddData(visitorCode, &types.CustomData{
		ID:    "1",
		Value: "some custom value",
	})

	client.FlushVisitor(visitorCode)
}

func renderFn(recommendedProductsNumber int) {
	panic("TODO")
}
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       go.mod                                                                                              0000664 0001750 0001750 00000000455 14056132746 012734  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              module development.kameleoon.net/sdk/go-sdk

go 1.15

require (
	github.com/cornelk/hashmap v1.0.1
	github.com/cristalhq/aconfig v0.13.3
	github.com/cristalhq/aconfig/aconfigyaml v0.12.0
	github.com/segmentio/encoding v0.2.17
	github.com/stretchr/testify v1.7.0
	github.com/valyala/fasthttp v1.23.0
)
                                                                                                                                                                                                                   go.sum                                                                                              0000664 0001750 0001750 00000011702 14056132746 012756  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              github.com/andybalholm/brotli v1.0.1 h1:KqhlKozYbRtJvsPrrEeXcO+N2l6NYT5A2QAFmSULpEc=
github.com/andybalholm/brotli v1.0.1/go.mod h1:loMXtMfwqflxFJPmdbJO0a3KNoPuLBgiu3qAvBg8x/Y=
github.com/cornelk/hashmap v1.0.1 h1:RXGcy29hEdLLV8T6aK4s+BAd4tq4+3Hq50N2GoG0uIg=
github.com/cornelk/hashmap v1.0.1/go.mod h1:8wbysTUDnwJGrPZ1Iwsou3m+An6sldFrJItjRhfegCw=
github.com/cristalhq/aconfig v0.11.1/go.mod h1:0ZBp7dUf0F2Jr7YbLjw8OVlAD0eeV2bU3NwmVgeUReo=
github.com/cristalhq/aconfig v0.13.3 h1:6L5ZxMXrLoNtsvdnlt5SfdNeOMjbV0XPLh0dd4hv5mk=
github.com/cristalhq/aconfig v0.13.3/go.mod h1:0ZBp7dUf0F2Jr7YbLjw8OVlAD0eeV2bU3NwmVgeUReo=
github.com/cristalhq/aconfig/aconfigyaml v0.12.0 h1:12xqSXacTprUFrPQEyqdntn/cs2U35qApw2pSXSPF44=
github.com/cristalhq/aconfig/aconfigyaml v0.12.0/go.mod h1:YkYG4p08h1katdK9TFeKdN9X5lHWV/o2pJuKLLQgSLU=
github.com/davecgh/go-spew v1.1.0 h1:ZDRjVQ15GmhC3fiQ8ni8+OwkZQO4DARzQgrnXU1Liz8=
github.com/davecgh/go-spew v1.1.0/go.mod h1:J7Y8YcW2NihsgmVo/mv3lAwl/skON4iLHjSsI+c5H38=
github.com/dchest/siphash v1.1.0 h1:1Rs9eTUlZLPBEvV+2sTaM8O0NWn0ppbgqS7p11aWawI=
github.com/dchest/siphash v1.1.0/go.mod h1:q+IRvb2gOSrUnYoPqHiyHXS0FOBBOdl6tONBlVnOnt4=
github.com/klauspost/compress v1.11.8 h1:difgzQsp5mdAz9v8lm3P/I+EpDKMU/6uTMw1y1FObuo=
github.com/klauspost/compress v1.11.8/go.mod h1:aoV0uJVorq1K+umq18yTdKaF57EivdYsUV+/s2qKfXs=
github.com/klauspost/cpuid/v2 v2.0.5 h1:qnfhwbFriwDIX51QncuNU5mEMf+6KE3t7O8V2KQl3Dg=
github.com/klauspost/cpuid/v2 v2.0.5/go.mod h1:FInQzS24/EEf25PyTYn52gqo7WaD8xa0213Md/qVLRg=
github.com/pmezard/go-difflib v1.0.0 h1:4DBwDE0NGyQoBHbLQYPwSUPoCMWR5BEzIk/f1lZbAQM=
github.com/pmezard/go-difflib v1.0.0/go.mod h1:iKH77koFhYxTK1pcRnkKkqfTogsbg7gZNVY4sRDYZ/4=
github.com/segmentio/encoding v0.2.17 h1:cgfmPc44u1po1lz5bSgF00gLCROBjDNc7h+H7I20zpc=
github.com/segmentio/encoding v0.2.17/go.mod h1:7E68jTSWMnNoYhHi1JbLd7NBSB6XfE4vzqhR88hDBQc=
github.com/stretchr/objx v0.1.0 h1:4G4v2dO3VZwixGIRoQ5Lfboy6nUhCyYzaqnIAPPhYs4=
github.com/stretchr/objx v0.1.0/go.mod h1:HFkY916IF+rwdDfMAkV7OtwuqBVzrE8GR6GFx+wExME=
github.com/stretchr/testify v1.7.0 h1:nwc3DEeHmmLAfoZucVR881uASk0Mfjw8xYJ99tb5CcY=
github.com/stretchr/testify v1.7.0/go.mod h1:6Fq8oRcR53rry900zMqJjRRixrwX3KX962/h/Wwjteg=
github.com/valyala/bytebufferpool v1.0.0 h1:GqA5TC/0021Y/b9FG4Oi9Mr3q7XYx6KllzawFIhcdPw=
github.com/valyala/bytebufferpool v1.0.0/go.mod h1:6bBcMArwyJ5K/AmCkWv1jt77kVWyCJ6HpOuEn7z0Csc=
github.com/valyala/fasthttp v1.23.0 h1:0ufwSD9BhWa6f8HWdmdq4FHQ23peRo3Ng/Qs8m5NcFs=
github.com/valyala/fasthttp v1.23.0/go.mod h1:0mw2RjXGOzxf4NL2jni3gUQ7LfjjUSiG5sskOUUSEpU=
github.com/valyala/tcplisten v0.0.0-20161114210144-ceec8f93295a/go.mod h1:v3UYOV9WzVtRmSR+PDvWpU/qWl4Wa5LApYYX4ZtKbio=
golang.org/x/crypto v0.0.0-20190308221718-c2843e01d9a2/go.mod h1:djNgcEr1/C05ACkg1iLfiJU5Ep61QUkGW8qpdssI0+w=
golang.org/x/crypto v0.0.0-20210220033148-5ea612d1eb83/go.mod h1:jdWPYTVW3xRLrWPugEBEK3UY2ZEsg3UU495nc5E+M+I=
golang.org/x/net v0.0.0-20190404232315-eb5bcb51f2a3/go.mod h1:t9HGtf8HONx5eT2rtn7q6eTqICYqUVnKs3thJo3Qplg=
golang.org/x/net v0.0.0-20210226101413-39120d07d75e h1:jIQURUJ9mlLvYwTBtRHm9h58rYhSonLvRvgAnP8Nr7I=
golang.org/x/net v0.0.0-20210226101413-39120d07d75e/go.mod h1:m0MpNAwzfU5UDzcl9v0D8zg8gWTRqZa9RBIspLL5mdg=
golang.org/x/sys v0.0.0-20190215142949-d0b11bdaac8a/go.mod h1:STP8DvDyc/dI5b8T5hshtkjS+E42TnysNCUPdjciGhY=
golang.org/x/sys v0.0.0-20191026070338-33540a1f6037/go.mod h1:h1NjWce9XRLGQEsW7wpKNCjG9DtNlClVuFLEZdDNbEs=
golang.org/x/sys v0.0.0-20201119102817-f84b799fce68/go.mod h1:h1NjWce9XRLGQEsW7wpKNCjG9DtNlClVuFLEZdDNbEs=
golang.org/x/sys v0.0.0-20210225134936-a50acf3fe073 h1:8qxJSnu+7dRq6upnbntrmriWByIakBuct5OM/MdQC1M=
golang.org/x/sys v0.0.0-20210225134936-a50acf3fe073/go.mod h1:h1NjWce9XRLGQEsW7wpKNCjG9DtNlClVuFLEZdDNbEs=
golang.org/x/term v0.0.0-20201117132131-f5c789dd3221/go.mod h1:Nr5EML6q2oocZ2LXRh80K7BxOlk5/8JxuGnuhpl+muw=
golang.org/x/term v0.0.0-20201126162022-7de9c90e9dd1/go.mod h1:bj7SfCRtBDWHUb9snDiAeCFNEtKQo2Wmx5Cou7ajbmo=
golang.org/x/text v0.3.0/go.mod h1:NqM8EUOU14njkJ3fqMW+pc6Ldnwhi/IjpwHt7yyuwOQ=
golang.org/x/text v0.3.3/go.mod h1:5Zoc/QRtKVWzQhOtBMvqHzDpF6irO9z98xDceosuGiQ=
golang.org/x/text v0.3.5 h1:i6eZZ+zk0SOf0xgBpEpPD18qWcJda6q1sxt3S0kzyUQ=
golang.org/x/text v0.3.5/go.mod h1:5Zoc/QRtKVWzQhOtBMvqHzDpF6irO9z98xDceosuGiQ=
golang.org/x/tools v0.0.0-20180917221912-90fa682c2a6e h1:FDhOuMEY4JVRztM/gsbk+IKUQ8kj74bxZrgw87eMMVc=
golang.org/x/tools v0.0.0-20180917221912-90fa682c2a6e/go.mod h1:n7NCudcB/nEzxVGmLbDWY5pfWTLqBcC2KZ6jyYvM4mQ=
gopkg.in/check.v1 v0.0.0-20161208181325-20d25e280405 h1:yhCVgyC4o1eVCa2tZl7eS0r+SDo693bJlVdllGtEeKM=
gopkg.in/check.v1 v0.0.0-20161208181325-20d25e280405/go.mod h1:Co6ibVJAznAaIkqp8huTwlJQCZ016jof/cbN4VW5Yz0=
gopkg.in/yaml.v2 v2.3.0 h1:clyUAQHOM3G0M3f5vQj7LuJrETvjVot3Z5el9nffUtU=
gopkg.in/yaml.v2 v2.3.0/go.mod h1:hI93XBmqTisBFMUTm0b8Fm+jr3Dg1NNxqwp+5A1VGuI=
gopkg.in/yaml.v3 v3.0.0-20200313102051-9f266ea9e77c h1:dUUwHk2QECo/6vqA44rthZ8ie2QXMNeKRTHCNY2nXvo=
gopkg.in/yaml.v3 v3.0.0-20200313102051-9f266ea9e77c/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
                                                              logger.go                                                                                           0000664 0001750 0001750 00000000264 14056132746 013432  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package kameleoon

import (
	"log"
	"os"
)

type Logger interface {
	Printf(format string, args ...interface{})
}

var defaultLogger Logger = log.New(os.Stdout, "", log.LstdFlags)
                                                                                                                                                                                                                                                                                                                                            rest.go                                                                                             0000664 0001750 0001750 00000006636 14056132746 013141  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package kameleoon

import (
	"crypto/tls"
	"strings"
	"time"

	"github.com/segmentio/encoding/json"
	"github.com/valyala/fasthttp"
	"github.com/valyala/fasthttp/fasthttpproxy"
)

const (
	HeaderContentTypeJson = "application/json"
	HeaderContentTypeForm = "application/x-www-form-urlencoded"
	HeaderContentTypeText = "text/plain"
	HeaderAuthorization   = "Authorization"
	HeaderPaginationCount = "X-Pagination-Page-Count"
	HeaderTracking        = "Kameleoon-Client"

	MethodGet  = fasthttp.MethodGet
	MethodPost = fasthttp.MethodPost
)

type restClient interface {
	Do(r request, callback respCallback) error
}

type rest struct {
	cfg *RestConfig
	c   *fasthttp.Client
}

type respCallback func(resp *fasthttp.Response, err error) error

func newRESTClient(cfg *RestConfig) restClient {
	c := &fasthttp.Client{
		Name:            cfg.UserAgent,
		ReadTimeout:     cfg.ReadTimeout,
		WriteTimeout:    cfg.WriteTimeout,
		MaxConnsPerHost: cfg.MaxConnsPerHost,
		TLSConfig: &tls.Config{
			InsecureSkipVerify: true,
		},
		NoDefaultUserAgentHeader: true, // Don't send: User-Agent: fasthttp
	}
	if len(cfg.ProxyURL) > 0 {
		c.Dial = fasthttpproxy.FasthttpHTTPDialer(cfg.ProxyURL)
	}
	return &rest{
		cfg: cfg,
		c:   c,
	}
}

func (c *rest) Do(r request, callback respCallback) error {
	req := fasthttp.AcquireRequest()
	req.Header.SetMethod(r.Method)
	req.Header.SetUserAgent(c.cfg.UserAgent)
	req.Header.SetRequestURI(r.URL)
	if len(r.AuthToken) > 0 {
		req.Header.Set(HeaderAuthorization, r.AuthToken)
	}
	if len(r.ContentType) > 0 {
		req.Header.SetContentType(r.ContentType)
	}
	if len(r.ClientHeader) > 0 {
		req.Header.Set(HeaderTracking, r.ClientHeader)
	}
	if r.Body != nil {
		req.SetBody(r.Body)
	} else if len(r.BodyString) > 0 {
		req.SetBodyString(r.BodyString)
	}
	timeout := r.Timeout
	if timeout == 0 {
		timeout = c.cfg.DoTimeout
	}
	resp := fasthttp.AcquireResponse()
	doErr := c.c.DoTimeout(req, resp, timeout)

	if callback == nil {
		callback = defaultRespCallback
	}
	err := callback(resp, doErr)

	fasthttp.ReleaseRequest(req)
	fasthttp.ReleaseResponse(resp)
	return err
}

type request struct {
	Method       string
	URL          string
	AuthToken    string
	ContentType  string
	BodyString   string
	Body         []byte
	Timeout      time.Duration
	ClientHeader string
}

func (r request) String() string {
	var s strings.Builder
	s.WriteString("method=")
	s.WriteString(r.Method)
	s.WriteString(", url=")
	s.WriteString(r.URL)
	if len(r.AuthToken) > 0 {
		s.WriteString(", auth_token=")
		s.WriteString(r.AuthToken)
	}
	if len(r.ContentType) > 0 {
		s.WriteString(", content_type=")
		s.WriteString(r.ContentType)
	}
	if r.Timeout > 0 {
		s.WriteString(", timeout=")
		s.WriteString(r.Timeout.String())
	}
	if len(r.ClientHeader) > 0 {
		s.WriteString(", client_header=")
		s.WriteString(r.ClientHeader)
	}
	if r.Body != nil {
		s.WriteString(", body=")
		s.Write(r.Body)
	} else if len(r.BodyString) > 0 {
		s.WriteString(", body=")
		s.WriteString(r.BodyString)
	}
	return s.String()
}

func respCallbackJson(i interface{}) respCallback {
	return func(resp *fasthttp.Response, err error) error {
		if err != nil {
			return err
		}
		if resp.StatusCode() >= fasthttp.StatusBadRequest {
			return ErrBadStatus
		}
		return json.Unmarshal(resp.Body(), i)
	}
}

var defaultRespCallback = func(resp *fasthttp.Response, err error) error {
	if err != nil {
		return err
	}
	if resp.StatusCode() >= fasthttp.StatusBadRequest {
		return ErrBadStatus
	}
	return nil
}
                                                                                                  targeting/                                                                                          0000775 0001750 0001750 00000000000 14056132746 013606  5                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              targeting/tree.go                                                                                   0000664 0001750 0001750 00000010000 14056132746 015063  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package targeting

import (
	"strconv"
	"strings"

	"development.kameleoon.net/sdk/go-sdk/targeting/conditions"
	"development.kameleoon.net/sdk/go-sdk/types"
)

type Tree struct {
	LeftTree   *Tree
	RightTree  *Tree
	Condition  types.Condition
	OrOperator bool
}

func (t *Tree) StringPadding(pads int) string {
	if t == nil {
		return ""
	}
	padding := strings.Repeat("    ", pads)
	var s strings.Builder
	s.WriteString(padding)
	s.WriteString("or_operator: ")
	s.WriteString(strconv.FormatBool(t.OrOperator))
	if t.Condition != nil {
		s.WriteByte('\n')
		s.WriteString(padding)
		s.WriteString("condition: ")
		s.WriteString(t.Condition.String())
	}
	if leftTree := t.LeftTree.StringPadding(pads + 1); len(leftTree) > 0 {
		s.WriteByte('\n')
		s.WriteString(padding)
		s.WriteString("left child:\n")
		s.WriteString(leftTree)
	}
	if rightTree := t.RightTree.StringPadding(pads + 1); len(rightTree) > 0 {
		s.WriteByte('\n')
		s.WriteString(padding)
		s.WriteString("right child:\n")
		s.WriteString(rightTree)
	}
	return s.String()
}

func (t *Tree) String() string {
	return t.StringPadding(0)
}

func (t *Tree) CheckTargeting(data []types.TargetingData) bool {
	if t.Condition != nil {
		return t.checkCondition(data)
	}

	var leftTargeted, rightTargeted bool
	if t.LeftTree == nil {
		leftTargeted = true
	} else {
		leftTargeted = t.LeftTree.CheckTargeting(data)
	}
	if t.OrOperator && leftTargeted {
		return leftTargeted
	}
	if t.RightTree == nil {
		rightTargeted = true
	} else {
		rightTargeted = t.RightTree.CheckTargeting(data)
	}
	if t.OrOperator && rightTargeted {
		return rightTargeted
	}
	return leftTargeted && rightTargeted
}

func (t *Tree) checkCondition(data []types.TargetingData) bool {
	targeted := t.Condition.CheckTargeting(data)
	if !t.Condition.GetInclude() {
		targeted = !targeted
	}
	return targeted
}

func NewTree(cd *types.ConditionsData) *Tree {
	return createFirstLevel(cd)
}

func createFirstLevel(cd *types.ConditionsData) *Tree {
	if len(cd.FirstLevel) == 0 {
		return nil
	}

	var leftTree *Tree
	var leftFirstLevel types.ConditionsFirstLevel
	leftFirstLevel, cd.FirstLevel = cd.FirstLevel[0], cd.FirstLevel[1:]
	leftTree = createSecondLevel(&leftFirstLevel)

	if len(cd.FirstLevel) == 0 {
		return leftTree
	}
	var orOperator bool
	orOperator, cd.FirstLevelOrOperators = cd.FirstLevelOrOperators[0], cd.FirstLevelOrOperators[1:]
	if orOperator {
		return &Tree{
			LeftTree:   leftTree,
			RightTree:  createFirstLevel(cd),
			OrOperator: orOperator,
		}
	}
	var rightFirstLevel types.ConditionsFirstLevel
	rightFirstLevel, cd.FirstLevel = cd.FirstLevel[0], cd.FirstLevel[1:]
	rightTree := createSecondLevel(&rightFirstLevel)
	t := &Tree{
		LeftTree:  leftTree,
		RightTree: rightTree,
	}
	if len(cd.FirstLevel) == 0 {
		return t
	}
	orOperator, cd.FirstLevelOrOperators = cd.FirstLevelOrOperators[0], cd.FirstLevelOrOperators[1:]
	return &Tree{
		LeftTree:   t,
		RightTree:  createFirstLevel(cd),
		OrOperator: orOperator,
	}
}

func createSecondLevel(fl *types.ConditionsFirstLevel) *Tree {
	if len(fl.Conditions) == 0 {
		return nil
	}
	var condition types.TargetingCondition
	condition, fl.Conditions = fl.Conditions[0], fl.Conditions[1:]
	leftTree := &Tree{
		Condition: getCondition(condition),
	}
	if len(fl.Conditions) == 0 {
		return leftTree
	}
	var orOperator bool
	orOperator, fl.OrOperators = fl.OrOperators[0], fl.OrOperators[1:]
	if orOperator {
		return &Tree{
			LeftTree:   leftTree,
			RightTree:  createSecondLevel(fl),
			OrOperator: orOperator,
		}
	}
	condition, fl.Conditions = fl.Conditions[0], fl.Conditions[1:]
	rightTree := &Tree{
		Condition: getCondition(condition),
	}
	t := &Tree{
		LeftTree:  leftTree,
		RightTree: rightTree,
	}
	if len(fl.Conditions) == 0 {
		return t
	}
	orOperator, fl.OrOperators = fl.OrOperators[0], fl.OrOperators[1:]
	return &Tree{
		LeftTree:   t,
		RightTree:  createSecondLevel(fl),
		OrOperator: orOperator,
	}
}

func getCondition(c types.TargetingCondition) types.Condition {
	switch c.GetType() {
	case types.TargetingCustomDatum:
		return conditions.NewCustomDatum(c)
	}
	return nil
}
targeting/conditions/                                                                               0000775 0001750 0001750 00000000000 14056132746 015757  5                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              targeting/conditions/custom.go                                                                      0000664 0001750 0001750 00000006074 14056132746 017627  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package conditions

import (
	"github.com/segmentio/encoding/json"
	"regexp"
	"strconv"
	"strings"

	"development.kameleoon.net/sdk/go-sdk/types"
)

func NewCustomDatum(c types.TargetingCondition) *CustomDatum {
	include := false
	if c.Include != nil {
		include = *c.Include
	}
	return &CustomDatum{
		Type:     c.Type,
		Operator: c.Operator,
		Value:    c.Value,
		ID:       c.ID,
		Index:    c.Index,
		Weight:   c.Weight,
		Include:  include,
	}
}

type CustomDatum struct {
	Value    interface{}         `json:"value"`
	Type     types.TargetingType `json:"targetingType"`
	Operator types.OperatorType  `json:"valueMatchType"`
	ID       int                 `json:"id"`
	Index    string              `json:"customDataIndex"`
	Weight   int                 `json:"weight"`
	Include  bool                `json:"include"`
}

func (c *CustomDatum) String() string {
	if c == nil {
		return ""
	}
	b, err := json.Marshal(c)
	if err != nil {
		return ""
	}
	var s strings.Builder
	s.Grow(len(b))
	s.Write(b)
	return s.String()
}

func (c CustomDatum) GetType() types.TargetingType {
	return c.Type
}

func (c *CustomDatum) SetType(t types.TargetingType) {
	c.Type = t
}

func (c CustomDatum) GetInclude() bool {
	return c.Include
}

func (c *CustomDatum) SetInclude(i bool) {
	c.Include = i
}

func (c *CustomDatum) CheckTargeting(targetData []types.TargetingData) bool {
	var customData []*types.CustomData
	for _, td := range targetData {
		if td.Data.DataType() != types.DataTypeCustom {
			continue
		}
		custom, ok := td.Data.(*types.CustomData)
		if ok && custom.ID == c.Index {
			customData = append(customData, custom)
		}
	}
	if len(customData) == 0 {
		return c.Operator == types.OperatorUndefined
	}
	customDatum := customData[len(customData)-1]
	switch c.Operator {
	case types.OperatorContains:
		str, ok1 := customDatum.Value.(string)
		value, ok2 := c.Value.(string)
		if !ok1 || !ok2 {
			return false
		}
		return strings.Contains(str, value)
	case types.OperatorExact:
		if c.Value == customDatum.Value {
			return true
		}
	case types.OperatorMatch:
		str, ok1 := customDatum.Value.(string)
		pattern, ok2 := c.Value.(string)
		if !ok1 || !ok2 {
			return false
		}
		matched, err := regexp.MatchString(pattern, str)
		if err == nil && matched {
			return true
		}
	case types.OperatorLower, types.OperatorGreater, types.OperatorEqual:
		var number int
		switch v := c.Value.(type) {
		case string:
			number, _ = strconv.Atoi(v)
		case int:
			number = v
		default:
			return false
		}
		var value int
		switch v := customDatum.Value.(type) {
		case string:
			value, _ = strconv.Atoi(v)
		case int:
			value = v
		default:
			return false
		}
		switch c.Operator {
		case types.OperatorLower:
			if value < number {
				return true
			}
		case types.OperatorEqual:
			if value == number {
				return true
			}
		case types.OperatorGreater:
			if value > number {
				return true
			}
		}
	case types.OperatorIsTrue:
		if val, ok := customDatum.Value.(bool); ok  && val {
			return true
		}
	case types.OperatorIsFalse:
		if val, ok := customDatum.Value.(bool); ok  && !val {
			return true
		}
	}
	return false
}
                                                                                                                                                                                                                                                                                                                                                                                                                                                                    targeting/segment_test.go                                                                           0000664 0001750 0001750 00000003110 14056132746 016631  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package targeting

import (
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/segmentio/encoding/json"
	"github.com/stretchr/testify/suite"

	"development.kameleoon.net/sdk/go-sdk/types"
)

func TestSegment(t *testing.T) {
	suite.Run(t, new(segmentTestSuite))
}

func loadFileJson(path string, i interface{}) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	return json.NewDecoder(file).Decode(i)
}

const SegmentAmount = 6

type segmentTestSuite struct {
	suite.Suite
	segments    []*Segment
	visitorData [][]visitorData
}

type visitorData struct {
	Data     []*types.CustomData `json:"data"`
	Targeted bool                `json:"targeted"`
}

func (s *segmentTestSuite) SetupSuite() {
	r := s.Require()
	for i := 0; i < SegmentAmount; i++ {
		seg := &types.Segment{}
		err := loadFileJson(fmt.Sprintf("../testdata/segments/segment%d.json", i), seg)
		r.NoError(err)
		s.segments = append(s.segments, NewSegment(seg))

		var vd []visitorData
		err = loadFileJson(fmt.Sprintf("../testdata/visitorsData/visitorsData%d.json", i), &vd)
		r.NoError(err)
		s.visitorData = append(s.visitorData, vd)
	}
}

func (s *segmentTestSuite) TestCheckTargeting() {
	r := s.Require()
	t := time.Now()
	for i, segment := range s.segments {
		for _, vd := range s.visitorData[i] {
			var data []types.TargetingData
			for _, customData := range vd.Data {
				data = append(data, types.TargetingData{
					Data:             customData,
					LastActivityTime: t,
				})
			}
			targeted := segment.CheckTargeting(data)
			r.Equalf(vd.Targeted, targeted, "segment %d, data: %v", i)
		}
	}
}
                                                                                                                                                                                                                                                                                                                                                                                                                                                        targeting/segment.go                                                                                0000664 0001750 0001750 00000001367 14056132746 015606  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package targeting

import (
	"strings"

	"development.kameleoon.net/sdk/go-sdk/types"
	"development.kameleoon.net/sdk/go-sdk/utils"
)

type Segment struct {
	ID   int
	Tree *Tree
	s    *types.Segment
}

func NewSegment(s *types.Segment) *Segment {
	return &Segment{
		ID:   s.ID,
		Tree: NewTree(s.ConditionsData),
		s:    s,
	}
}

func (s Segment) String() string {
	var b strings.Builder
	b.WriteString("\nSegment id: ")
	b.WriteString(utils.WriteUint(s.ID))
	b.WriteByte('\n')
	tree := s.Tree.String()
	b.WriteString(tree)
	return b.String()
}

func (s Segment) Data() *types.Segment {
	return s.s
}

func (s *Segment) CheckTargeting(data []types.TargetingData) bool {
	if s == nil || s.Tree == nil {
		return true
	}
	return s.Tree.CheckTargeting(data)
}
                                                                                                                                                                                                                                                                         test-app/                                                                                           0000775 0001750 0001750 00000000000 14056132746 013357  5                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              test-app/integration_app_test.go                                                                    0000664 0001750 0001750 00000014047 14056132746 020136  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package test_app

import (
	"crypto/tls"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/segmentio/encoding/json"
	"github.com/stretchr/testify/suite"
	"github.com/valyala/fasthttp"

	kameleoon "development.kameleoon.net/sdk/go-sdk"
)

func TestApp(t *testing.T) {
	suite.Run(t, new(integrationSuite))
}

type integrationSuite struct {
	suite.Suite
	s   *Server
	c   *fasthttp.Client
	cfg *Config
}

func (s *integrationSuite) SetupSuite() {
	var err error
	s.cfg = &Config{
		Addr:       "127.0.0.1:3000",
		ConfigPath: "./kameleoon.yml",
	}
	s.s, err = NewServer(s.cfg)
	r := s.Require()
	r.NoError(err)

	s.c = &fasthttp.Client{
		TLSConfig: &tls.Config{
			InsecureSkipVerify: true,
		},
		NoDefaultUserAgentHeader: true, // Don't send: User-Agent: fasthttp
	}
	s.s.Run()
	time.Sleep(5 * time.Second)
	ok, err := s.checkClientIsReady(10)
	r.NoError(err, "Client is not ready, tests will fail...")
	r.True(ok, "Client is not ready, tests will fail...")
	s.T().Log("Client is ready, starting test...")
}

func (s *integrationSuite) checkClientIsReady(trials int) (bool, error) {
	t := time.NewTicker(2 * time.Second)
	defer t.Stop()
	for {
		<-t.C
		if trials < 0 {
			s.T().Log("No more trials allowed")
			break
		}
		req := fasthttp.AcquireRequest()
		req.SetRequestURI("/test")
		req.SetHost(s.cfg.Addr)
		resp := fasthttp.AcquireResponse()
		if err := s.c.Do(req, resp); err != nil {
			fasthttp.ReleaseRequest(req)
			fasthttp.ReleaseResponse(resp)
			s.T().Log(err)
			continue
		}
		data := make(map[string]interface{})
		err := json.Unmarshal(resp.Body(), &data)
		fasthttp.ReleaseRequest(req)
		fasthttp.ReleaseResponse(resp)
		if err != nil {
			trials--
			s.T().Log(err)
			continue
		}
		if _, ok := data["variation"]; !ok {
			trials--
			continue
		}
		return true, nil
	}
	return false, nil
}

func parseVisitorCode(resp *fasthttp.Response) string {
	c := fasthttp.AcquireCookie()
	defer fasthttp.ReleaseCookie(c)
	err := c.ParseBytes(resp.Header.PeekCookie(kameleoon.CookieName))
	if err != nil {
		return ""
	}

	return string(c.Value())
}

func (s *integrationSuite) TestActivate() {
	visitorCode := "test_visitor_cod"
	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)
	req.SetRequestURI("/activate")
	req.SetHost(s.cfg.Addr)
	req.Header.SetCookie(kameleoon.CookieName, visitorCode)
	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseResponse(resp)
	err := s.c.Do(req, resp)
	r := s.Require()
	r.NoError(err)

	body := resp.Body()
	r.NotEmpty(body)
	data := make(map[string]interface{})
	err = json.Unmarshal(body, &data)
	r.NoError(err)
	r.Equal(true, data["activate"])
}

func (s *integrationSuite) TestGetReference() {
	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)
	req.SetRequestURI("/test")
	req.SetHost(s.cfg.Addr)
	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseResponse(resp)
	err := s.c.Do(req, resp)
	r := s.Require()
	r.NoError(err)

	body := resp.Body()
	r.NotEmpty(body)
	data := make(map[string]interface{})
	err = json.Unmarshal(body, &data)
	r.NoError(err)
	r.Equal("reference", data["variation"])
}

func (s *integrationSuite) TestGetVariation() {
	r := s.Require()

	var path strings.Builder
	path.WriteString("/add-data?")

	encData := []map[string]string{{"id": "2", "value": "test_kameleoon"}}
	b, err := json.Marshal(&encData)
	r.NoError(err)
	path.WriteString(url.Values{"data": []string{string(b)}}.Encode())

	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)
	req.SetRequestURI(path.String())
	req.SetHost(s.cfg.Addr)
	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseResponse(resp)
	err = s.c.Do(req, resp)
	r.NoError(err)

	visitorCode := parseVisitorCode(resp)
	r.NotEmpty(visitorCode)

	req.Reset()
	resp.Reset()
	req.SetRequestURI("/test")
	req.SetHost(s.cfg.Addr)
	req.Header.SetCookie(kameleoon.CookieName, visitorCode)
	err = s.c.Do(req, resp)
	r.NoError(err)

	body := resp.Body()
	r.NotEmpty(body)
	data := make(map[string]interface{})
	err = json.Unmarshal(body, &data)
	r.NoError(err)
	varId, ok := data["variation"]
	r.True(ok)
	r.False(varId != "550104" && varId != "550105" && varId != "550106")
}

func (s *integrationSuite) TestGetBlocking() {
	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)
	req.SetRequestURI("/test?blocking=true")
	req.SetHost(s.cfg.Addr)
	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseResponse(resp)
	err := s.c.Do(req, resp)
	r := s.Require()
	r.NoError(err)

	body := resp.Body()
	r.NotEmpty(body)
	data := make(map[string]interface{})
	err = json.Unmarshal(body, &data)
	r.NoError(err)
	varId, ok := data["variation"]
	r.True(ok)
	r.False(varId != "550104" && varId != "550105" && varId != "550106" && varId != "reference")
}

func (s *integrationSuite) TestFlush() {
	r := s.Require()

	var path strings.Builder
	path.WriteString("/add-data?")
	encData := []map[string]string{{"id": "1", "value": "test_flush"}}
	b, err := json.Marshal(&encData)
	r.NoError(err)
	path.WriteString(url.Values{"data": []string{string(b)}}.Encode())

	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)
	req.SetRequestURI(path.String())
	req.SetHost(s.cfg.Addr)
	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseResponse(resp)
	err = s.c.Do(req, resp)
	r.NoError(err)

	visitorCode := parseVisitorCode(resp)
	r.NotEmpty(visitorCode)

	req.Reset()
	resp.Reset()
	path.Reset()
	encData[0]["id"] = "2"
	path.WriteString("/add-data?")
	b, err = json.Marshal(&encData)
	r.NoError(err)
	path.WriteString(url.Values{"data": []string{string(b)}}.Encode())

	req.SetRequestURI(path.String())
	req.SetHost(s.cfg.Addr)
	req.Header.SetCookie(kameleoon.CookieName, visitorCode)

	err = s.c.Do(req, resp)
	r.NoError(err)

	req.Reset()
	resp.Reset()

	req.SetRequestURI("/flush")
	req.SetHost(s.cfg.Addr)
	req.Header.SetCookie(kameleoon.CookieName, visitorCode)
	err = s.c.Do(req, resp)
	r.NoError(err)
	<-time.After(5 * time.Second)
	resp.Reset()
	err = s.c.Do(req, resp)
	r.NoError(err)

	body := resp.Body()
	r.NotEmpty(body)
	dd := make(map[string]interface{})
	err = json.Unmarshal(body, &dd)
	r.NoError(err)
	data, ok := dd["data"]
	r.True(ok)
	s.T().Log(data)
}
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         test-app/server.go                                                                                  0000664 0001750 0001750 00000001402 14056132746 015211  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package test_app

import (
	"log"

	"github.com/gofiber/fiber/v2"
)

type Config struct {
	Addr       string
	ConfigPath string
}

type Server struct {
	*fiber.App
	cfg *Config
	c   *Controller
}

func NewServer(cfg *Config) (*Server, error) {
	s := &Server{
		App: fiber.New(),
		cfg: cfg,
	}
	var err error
	s.c, err = NewController(cfg.ConfigPath)
	if err != nil {
		return nil, err
	}

	s.setupRoutes()
	return s, nil
}

func (s *Server) setupRoutes() {
	s.Get("/flush", s.c.HandleFlush)
	s.Get("/add-data", s.c.HandleAddData)
	s.Get("/test", s.c.HandleTest)
	s.Get("/activate", s.c.HandleActivate)
	//s.Get("/activate/index", s.c.HandleActivate)
}

func (s *Server) Run() {
	go func() {
		if err := s.Listen(s.cfg.Addr); err != nil {
			log.Panicln(err)
		}
	}()
}
                                                                                                                                                                                                                                                              test-app/controller.go                                                                              0000664 0001750 0001750 00000005661 14056132746 016101  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package test_app

import (
	"errors"

	"github.com/gofiber/fiber/v2"
	"github.com/segmentio/encoding/json"

	kameleoon "development.kameleoon.net/sdk/go-sdk"
	"development.kameleoon.net/sdk/go-sdk/types"
	"development.kameleoon.net/sdk/go-sdk/utils"
)

func NewController(path string) (*Controller, error) {
	cfg, err := kameleoon.LoadConfig(path)
	if err != nil {
		return nil, err
	}
	return &Controller{client: kameleoon.NewClient(cfg)}, nil
}

type Controller struct {
	client *kameleoon.Client
}

func (c *Controller) HandleFlush(ctx *fiber.Ctx) error {
	c.client.FlushAll()

	all := make(fiber.Map)
	for kv := range c.client.Data.Iter() {
		key, ok := kv.Key.(string)
		if !ok {
			continue
		}
		all[key] = kv.Value
	}
	return ctx.JSON(fiber.Map{"data": all})
}

func (c *Controller) HandleTest(ctx *fiber.Ctx) error {
	visitorCode := c.client.GetVisitorCode(ctx.Request())
	c.client.SetVisitorCode(ctx.Response(), visitorCode, "")
	experimentId := 127854

	//ex := c.client.GetExperiment(experimentId)
	if 	blocking := ctx.Query("blocking"); len(blocking) > 0 {
		c.client.Cfg.BlockingMode = true
	}

	varId, err := c.client.TriggerExperiment(visitorCode, experimentId)
	if err != nil {
		errNotActive := &kameleoon.ErrNotActivated{}
		errNotTarget := &kameleoon.ErrNotTargeted{}
		if errors.As(err, &errNotActive) || errors.As(err, &errNotTarget) {
			varId = -1
		} else {
			return ctx.Status(fiber.StatusInternalServerError).JSON(fiber.Map{"error": err.Error()})
		}
	}

	c.client.Cfg.BlockingMode = false
	var variation string
	if varId == -1 {
		variation = "reference"
	} else {
		variation = utils.WriteUint(varId)
	}
	return ctx.JSON(fiber.Map{"visitor_code": visitorCode, "variation": variation})
}

func (c *Controller) HandleActivate(ctx *fiber.Ctx) error {
	visitorCode := c.client.GetVisitorCode(ctx.Request())
	c.client.SetVisitorCode(ctx.Response(), visitorCode, "")

	featureKey := "test-sdk"
	activated, err := c.client.ActivateFeature(visitorCode, featureKey)
	if err != nil {
		return ctx.Status(fiber.StatusInternalServerError).JSON(fiber.Map{"error": err.Error()})
	}
	return ctx.JSON(fiber.Map{"visitor_code": visitorCode, "activate": activated})
}

func (c *Controller) HandleAddData(ctx *fiber.Ctx) error {
	dataParam := ctx.Query("data")
	if len(dataParam) == 0 {
		return ctx.Status(fiber.StatusBadRequest).JSON(fiber.Map{"error": "empty data"})
	}
	var data []map[string]string
	if err := json.Unmarshal([]byte(dataParam), &data); err != nil {
		return ctx.Status(fiber.StatusBadRequest).JSON(fiber.Map{"error": err.Error()})
	}
	visitorCode := c.client.GetVisitorCode(ctx.Request())
	c.client.SetVisitorCode(ctx.Response(), visitorCode, "")
	for _, d := range data {
		c.client.AddData(visitorCode, &types.CustomData{
			ID:    d["id"],
			Value: d["value"],
		})
	}

	all := make(fiber.Map)
	for kv := range c.client.Data.Iter() {
		key, ok := kv.Key.(string)
		if !ok {
			continue
		}
		all[key] = kv.Value
	}
	return ctx.JSON(fiber.Map{"data": all})
}
                                                                               test-app/kameleoon.yml                                                                              0000664 0001750 0001750 00000000401 14056132746 016047  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              client_id: "CLIENT_ID"
client_secret: "CLIENT_SECRET"
config_update_interval: 1m
visitor_data_max_size: 500
site_code: "nfv42afnay"
tracking_url: "https://api-ssx.kameleoon.net"
proxy_url: ""
verbose_mode: true                                                                                                                                                                                                                                                               test-app/go.mod                                                                                     0000664 0001750 0001750 00000000435 14056132746 014467  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              module test-app

go 1.15

require (
	development.kameleoon.net/sdk/go-sdk v0.0.0
	github.com/gofiber/fiber/v2 v2.9.0
	github.com/segmentio/encoding v0.2.17
	github.com/stretchr/testify v1.7.0
	github.com/valyala/fasthttp v1.23.0
)

replace development.kameleoon.net/sdk/go-sdk => ../.
                                                                                                                                                                                                                                   test-app/go.sum                                                                                     0000664 0001750 0001750 00000012043 14056132746 014512  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              github.com/andybalholm/brotli v1.0.1 h1:KqhlKozYbRtJvsPrrEeXcO+N2l6NYT5A2QAFmSULpEc=
github.com/andybalholm/brotli v1.0.1/go.mod h1:loMXtMfwqflxFJPmdbJO0a3KNoPuLBgiu3qAvBg8x/Y=
github.com/cornelk/hashmap v1.0.1 h1:RXGcy29hEdLLV8T6aK4s+BAd4tq4+3Hq50N2GoG0uIg=
github.com/cornelk/hashmap v1.0.1/go.mod h1:8wbysTUDnwJGrPZ1Iwsou3m+An6sldFrJItjRhfegCw=
github.com/cristalhq/aconfig v0.11.1/go.mod h1:0ZBp7dUf0F2Jr7YbLjw8OVlAD0eeV2bU3NwmVgeUReo=
github.com/cristalhq/aconfig v0.13.3 h1:6L5ZxMXrLoNtsvdnlt5SfdNeOMjbV0XPLh0dd4hv5mk=
github.com/cristalhq/aconfig v0.13.3/go.mod h1:0ZBp7dUf0F2Jr7YbLjw8OVlAD0eeV2bU3NwmVgeUReo=
github.com/cristalhq/aconfig/aconfigyaml v0.12.0 h1:12xqSXacTprUFrPQEyqdntn/cs2U35qApw2pSXSPF44=
github.com/cristalhq/aconfig/aconfigyaml v0.12.0/go.mod h1:YkYG4p08h1katdK9TFeKdN9X5lHWV/o2pJuKLLQgSLU=
github.com/davecgh/go-spew v1.1.0 h1:ZDRjVQ15GmhC3fiQ8ni8+OwkZQO4DARzQgrnXU1Liz8=
github.com/davecgh/go-spew v1.1.0/go.mod h1:J7Y8YcW2NihsgmVo/mv3lAwl/skON4iLHjSsI+c5H38=
github.com/dchest/siphash v1.1.0 h1:1Rs9eTUlZLPBEvV+2sTaM8O0NWn0ppbgqS7p11aWawI=
github.com/dchest/siphash v1.1.0/go.mod h1:q+IRvb2gOSrUnYoPqHiyHXS0FOBBOdl6tONBlVnOnt4=
github.com/gofiber/fiber/v2 v2.9.0 h1:sZsTKlbyGGZ0UdTUn3ItQv5J9FTQUc4J3OS+03lE5m0=
github.com/gofiber/fiber/v2 v2.9.0/go.mod h1:Ah3IJikrKNRepl/HuVawppS25X7FWohwfCSRn7kJG28=
github.com/klauspost/compress v1.11.8/go.mod h1:aoV0uJVorq1K+umq18yTdKaF57EivdYsUV+/s2qKfXs=
github.com/klauspost/compress v1.11.13 h1:eSvu8Tmq6j2psUJqJrLcWH6K3w5Dwc+qipbaA6eVEN4=
github.com/klauspost/compress v1.11.13/go.mod h1:aoV0uJVorq1K+umq18yTdKaF57EivdYsUV+/s2qKfXs=
github.com/klauspost/cpuid/v2 v2.0.5 h1:qnfhwbFriwDIX51QncuNU5mEMf+6KE3t7O8V2KQl3Dg=
github.com/klauspost/cpuid/v2 v2.0.5/go.mod h1:FInQzS24/EEf25PyTYn52gqo7WaD8xa0213Md/qVLRg=
github.com/pmezard/go-difflib v1.0.0 h1:4DBwDE0NGyQoBHbLQYPwSUPoCMWR5BEzIk/f1lZbAQM=
github.com/pmezard/go-difflib v1.0.0/go.mod h1:iKH77koFhYxTK1pcRnkKkqfTogsbg7gZNVY4sRDYZ/4=
github.com/segmentio/encoding v0.2.17 h1:cgfmPc44u1po1lz5bSgF00gLCROBjDNc7h+H7I20zpc=
github.com/segmentio/encoding v0.2.17/go.mod h1:7E68jTSWMnNoYhHi1JbLd7NBSB6XfE4vzqhR88hDBQc=
github.com/stretchr/objx v0.1.0/go.mod h1:HFkY916IF+rwdDfMAkV7OtwuqBVzrE8GR6GFx+wExME=
github.com/stretchr/testify v1.7.0 h1:nwc3DEeHmmLAfoZucVR881uASk0Mfjw8xYJ99tb5CcY=
github.com/stretchr/testify v1.7.0/go.mod h1:6Fq8oRcR53rry900zMqJjRRixrwX3KX962/h/Wwjteg=
github.com/valyala/bytebufferpool v1.0.0 h1:GqA5TC/0021Y/b9FG4Oi9Mr3q7XYx6KllzawFIhcdPw=
github.com/valyala/bytebufferpool v1.0.0/go.mod h1:6bBcMArwyJ5K/AmCkWv1jt77kVWyCJ6HpOuEn7z0Csc=
github.com/valyala/fasthttp v1.23.0 h1:0ufwSD9BhWa6f8HWdmdq4FHQ23peRo3Ng/Qs8m5NcFs=
github.com/valyala/fasthttp v1.23.0/go.mod h1:0mw2RjXGOzxf4NL2jni3gUQ7LfjjUSiG5sskOUUSEpU=
github.com/valyala/tcplisten v0.0.0-20161114210144-ceec8f93295a h1:0R4NLDRDZX6JcmhJgXi5E4b8Wg84ihbmUKp/GvSPEzc=
github.com/valyala/tcplisten v0.0.0-20161114210144-ceec8f93295a/go.mod h1:v3UYOV9WzVtRmSR+PDvWpU/qWl4Wa5LApYYX4ZtKbio=
golang.org/x/crypto v0.0.0-20190308221718-c2843e01d9a2/go.mod h1:djNgcEr1/C05ACkg1iLfiJU5Ep61QUkGW8qpdssI0+w=
golang.org/x/crypto v0.0.0-20210220033148-5ea612d1eb83/go.mod h1:jdWPYTVW3xRLrWPugEBEK3UY2ZEsg3UU495nc5E+M+I=
golang.org/x/net v0.0.0-20190404232315-eb5bcb51f2a3/go.mod h1:t9HGtf8HONx5eT2rtn7q6eTqICYqUVnKs3thJo3Qplg=
golang.org/x/net v0.0.0-20210226101413-39120d07d75e h1:jIQURUJ9mlLvYwTBtRHm9h58rYhSonLvRvgAnP8Nr7I=
golang.org/x/net v0.0.0-20210226101413-39120d07d75e/go.mod h1:m0MpNAwzfU5UDzcl9v0D8zg8gWTRqZa9RBIspLL5mdg=
golang.org/x/sys v0.0.0-20190215142949-d0b11bdaac8a/go.mod h1:STP8DvDyc/dI5b8T5hshtkjS+E42TnysNCUPdjciGhY=
golang.org/x/sys v0.0.0-20191026070338-33540a1f6037/go.mod h1:h1NjWce9XRLGQEsW7wpKNCjG9DtNlClVuFLEZdDNbEs=
golang.org/x/sys v0.0.0-20201119102817-f84b799fce68/go.mod h1:h1NjWce9XRLGQEsW7wpKNCjG9DtNlClVuFLEZdDNbEs=
golang.org/x/sys v0.0.0-20210225134936-a50acf3fe073 h1:8qxJSnu+7dRq6upnbntrmriWByIakBuct5OM/MdQC1M=
golang.org/x/sys v0.0.0-20210225134936-a50acf3fe073/go.mod h1:h1NjWce9XRLGQEsW7wpKNCjG9DtNlClVuFLEZdDNbEs=
golang.org/x/term v0.0.0-20201117132131-f5c789dd3221/go.mod h1:Nr5EML6q2oocZ2LXRh80K7BxOlk5/8JxuGnuhpl+muw=
golang.org/x/term v0.0.0-20201126162022-7de9c90e9dd1/go.mod h1:bj7SfCRtBDWHUb9snDiAeCFNEtKQo2Wmx5Cou7ajbmo=
golang.org/x/text v0.3.0/go.mod h1:NqM8EUOU14njkJ3fqMW+pc6Ldnwhi/IjpwHt7yyuwOQ=
golang.org/x/text v0.3.3/go.mod h1:5Zoc/QRtKVWzQhOtBMvqHzDpF6irO9z98xDceosuGiQ=
golang.org/x/text v0.3.5 h1:i6eZZ+zk0SOf0xgBpEpPD18qWcJda6q1sxt3S0kzyUQ=
golang.org/x/text v0.3.5/go.mod h1:5Zoc/QRtKVWzQhOtBMvqHzDpF6irO9z98xDceosuGiQ=
golang.org/x/tools v0.0.0-20180917221912-90fa682c2a6e/go.mod h1:n7NCudcB/nEzxVGmLbDWY5pfWTLqBcC2KZ6jyYvM4mQ=
gopkg.in/check.v1 v0.0.0-20161208181325-20d25e280405/go.mod h1:Co6ibVJAznAaIkqp8huTwlJQCZ016jof/cbN4VW5Yz0=
gopkg.in/yaml.v2 v2.3.0 h1:clyUAQHOM3G0M3f5vQj7LuJrETvjVot3Z5el9nffUtU=
gopkg.in/yaml.v2 v2.3.0/go.mod h1:hI93XBmqTisBFMUTm0b8Fm+jr3Dg1NNxqwp+5A1VGuI=
gopkg.in/yaml.v3 v3.0.0-20200313102051-9f266ea9e77c h1:dUUwHk2QECo/6vqA44rthZ8ie2QXMNeKRTHCNY2nXvo=
gopkg.in/yaml.v3 v3.0.0-20200313102051-9f266ea9e77c/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             testdata/                                                                                           0000775 0001750 0001750 00000000000 14056132746 013433  5                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              testdata/client-go.yaml                                                                             0000664 0001750 0001750 00000000364 14056132746 016203  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              client_id: "CLIENT_ID"
client_secret: "CLIENT_SECRET"
site_code: "nfv42afnay"
config_update_interval: 5m
timeout: 1s
visitor_data_max_size: 500
proxy_url: ""
blocking_mode: false
verbose_mode: true                                                                                                                                                                                                                                                                            testdata/segments/                                                                                  0000775 0001750 0001750 00000000000 14056132746 015260  5                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              testdata/segments/segment1.json                                                                     0000664 0001750 0001750 00000001664 14056132746 017705  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              {
  "id": 151875,
  "name": "Test segment 1",
  "description": "Simple segment with two conditions and and operator",
  "conditionsData": {
    "firstLevelOrOperators": [],
    "firstLevel": [
      {
        "orOperators": [false],
        "conditions": [
          {
            "id": 860285,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "1",
            "value": "test_1",
            "valueMatchType": "CONTAINS",
            "include": true
          },
          {
            "id": 860286,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "2",
            "value": "test_2",
            "valueMatchType": "CONTAINS",
            "include": true
          }
        ]
      }
    ]
  },
  "siteId": 21392,
  "audienceTracking": false,
  "audienceTrackingEditable": true,
  "isFavorite": false,
  "dateCreated": "2021-03-26T10:41:38"
}                                                                            testdata/segments/segment4.json                                                                     0000664 0001750 0001750 00000002051 14056132746 017677  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              {
  "id": 151875,
  "name": "Test segment 4",
  "description": "Custom test segment for SDK with regex expressions",
  "conditionsData": {
    "firstLevelOrOperators": [true, true],
    "firstLevel": [
      {
        "orOperators": [],
        "conditions": [
          {
            "id": 860285,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "1",
            "value": "^[a-zA-Z]*$",
            "valueMatchType": "REGULAR_EXPRESSION",
            "include": true
          }
        ]
      },
      {
        "orOperators": [],
        "conditions": [
          {
            "id": 860286,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "2",
            "value": "^(test_)[0-9]{3}$",
            "valueMatchType": "REGULAR_EXPRESSION",
            "include": true
          }
        ]
      }
    ]
  },
  "siteId": 21392,
  "audienceTracking": false,
  "audienceTrackingEditable": true,
  "isFavorite": false,
  "dateCreated": "2021-03-26T10:41:38"
}                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       testdata/segments/segment5.json                                                                     0000664 0001750 0001750 00000001241 14056132746 017700  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              {
  "id": 151875,
  "name": "Test segment 5",
  "description": "Test segment with front conditions.",
  "conditionsData": {
    "firstLevelOrOperators": [true],
    "firstLevel": [
      {
        "orOperators": [],
        "conditions": [
          {
            "id": 860285,
            "targetingType": "PAGE_URL"
          }
        ]
      },
      {
        "orOperators": [],
        "conditions": [
          {
            "id": 860286,
            "targetingType": "BROWSER"
          }
        ]
      }
    ]
  },
  "siteId": 21392,
  "audienceTracking": false,
  "audienceTrackingEditable": true,
  "isFavorite": false,
  "dateCreated": "2021-03-26T10:41:38"
}                                                                                                                                                                                                                                                                                                                                                               testdata/segments/segment0.json                                                                     0000664 0001750 0001750 00000001701 14056132746 017674  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              {
  "id": 148586,
  "name": "Test segment 0",
  "description": "Simple segment with 2 conditions and or operator.",
  "conditionsData": {
    "firstLevelOrOperators": [
      true
    ],
    "firstLevel": [
      {
        "orOperators": [true],
        "conditions": [
          {
            "id": 860285,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "1",
            "value": "test_1",
            "valueMatchType": "CONTAINS",
            "include": true
          },
          {
            "id": 860286,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "2",
            "value": "test_2",
            "valueMatchType": "CONTAINS",
            "include": true
          }
        ]
      }
    ]
  },
  "siteId": 21392,
  "audienceTracking": false,
  "audienceTrackingEditable": true,
  "isFavorite": false,
  "dateCreated": "2021-02-08T08:07:02"
}                                                               testdata/segments/segment2.json                                                                     0000664 0001750 0001750 00000002431 14056132746 017677  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              {
  "id": 151894,
  "name": "Test segment 2",
  "description": "This is a simple segment mixing 3 conditions and or/and operators, on multi-levels.",
  "conditionsData": {
    "firstLevelOrOperators": [false],
    "firstLevel": [
      {
        "orOperators": [],
        "conditions": [
          {
            "id": 860459,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "1",
            "value": "10",
            "valueMatchType": "GREATER",
            "include": true
          }
        ]
      },
      {
        "orOperators": [true],
        "conditions": [
          {
            "id": 860460,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "2",
            "value": "10",
            "valueMatchType": "LOWER",
            "include": true
          },
          {
            "id": 860461,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "3",
            "value": "test",
            "valueMatchType": "CONTAINS",
            "include": true
          }
        ]
      }
    ]
  },
  "siteId": 21392,
  "audienceTracking": false,
  "audienceTrackingEditable": true,
  "isFavorite": false,
  "dateCreated": "2021-03-26T13:48:09"
}                                                                                                                                                                                                                                       testdata/segments/segment3.json                                                                     0000664 0001750 0001750 00000004141 14056132746 017700  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              {
  "id": 148586,
  "name": "Test segment 3",
  "description": "Test segment 3 mixing multiple custom condition on multiple levels.",
  "conditionsData": {
    "firstLevelOrOperators": [false, true],
    "firstLevel": [
      {
        "orOperators": [true, true],
        "conditions": [
          {
            "id": 860459,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "1",
            "value": "10",
            "valueMatchType": "GREATER",
            "include": true
          },
          {
            "id": 860460,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "2",
            "value": "test",
            "valueMatchType": "CONTAINS",
            "include": true
          },
          {
            "id": 860461,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "3",
            "value": "test",
            "valueMatchType": "EXACT",
            "include": true
          }
        ]
      },
      {
        "orOperators": [],
        "conditions": [
          {
            "id": 860462,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "4",
            "value": "",
            "valueMatchType": "TRUE",
            "include": false
          }
        ]
      },
      {
        "orOperators": [true],
        "conditions": [
          {
            "id": 860465,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "5",
            "value": "10",
            "valueMatchType": "EQUAL",
            "include": true
          },
          {
            "id": 860466,
            "targetingType": "CUSTOM_DATUM",
            "weight": 1,
            "customDataIndex": "6",
            "value": "kameleoon",
            "valueMatchType": "CONTAINS",
            "include": true
          }
        ]
      }
    ]
  },
  "siteId": 21392,
  "audienceTracking": false,
  "audienceTrackingEditable": true,
  "isFavorite": false,
  "dateCreated": "2021-02-08T08:07:02"
}                                                                                                                                                                                                                                                                                                                                                                                                                               testdata/visitorsData/                                                                              0000775 0001750 0001750 00000000000 14056132746 016107  5                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              testdata/visitorsData/visitorsData1.json                                                            0000664 0001750 0001750 00000001506 14056132746 021541  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              [
  {
    "data": [
      {
        "value":"test_1",
        "id": "1"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"test_2",
        "id": "2"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"test_3",
        "id": "3"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"test_1",
        "id": "1"
      }, {
        "value":"test_2",
        "id": "2"
      }
    ],
    "targeted": true
  },
  {
    "data": [
      {
        "value":"test_1",
        "id": "1"
      }, {
        "value":"test_3",
        "id": "3"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"test_1",
        "id": "1"
      }, {
        "value":"test_3",
        "id": "2"
      }
    ],
    "targeted": false
  }
]                                                                                                                                                                                          testdata/visitorsData/visitorsData2.json                                                            0000664 0001750 0001750 00000001547 14056132746 021547  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              [
  {
    "data": [
      {
        "value":"9",
        "id": "1"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"11",
        "id": "1"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"11",
        "id": "1"
      },
      {
        "value":"9",
        "id": "2"
      }
    ],
    "targeted": true
  },
  {
    "data": [
      {
        "value":"11",
        "id": "1"
      },
      {
        "value":"test_1",
        "id": "3"
      }
    ],
    "targeted": true
  },
  {
    "data": [
      {
        "value":"9",
        "id": "2"
      }, {
        "value":"test_3",
        "id": "3"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"12",
        "id": "2"
      }, {
        "value":"test",
        "id": "1"
      }
    ],
    "targeted": false
  }
]                                                                                                                                                         testdata/visitorsData/visitorsData0.json                                                            0000664 0001750 0001750 00000001152 14056132746 021535  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              [
  {
    "data": [
      {
        "value":"test_1",
        "id": "1"
      }
    ],
    "targeted": true
  },
  {
    "data": [
      {
        "value":"test_2",
        "id": "2"
      }
    ],
    "targeted": true
  },
  {
    "data": [
      {
        "value":"test_3",
        "id": "3"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"test_1",
        "id": "1"
      }, {
        "value":"test_2",
        "id": "2"
      }
    ],
    "targeted": true
  },
  {
    "data": [
      {
        "value":"test_false",
        "id": "1"
      }
    ],
    "targeted": false
  }
]                                                                                                                                                                                                                                                                                                                                                                                                                      testdata/visitorsData/visitorsData3.json                                                            0000664 0001750 0001750 00000001332 14056132746 021540  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              [
  {
    "data": [
      {
        "value":"test_kameleoon",
        "id": "6"
      }
    ],
    "targeted": true
  },
  {
    "data": [
      {
        "value":"10",
        "id": "5"
      }
    ],
    "targeted": true
  },
  {
    "data": [
      {
        "value":"11",
        "id": "5"
      },
      {
        "value": "WRONG",
        "id": "10"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"11",
        "id": "1"
      },
      {
        "value": false,
        "id": "4"
      }
    ],
    "targeted": true
  },
  {
    "data": [
      {
        "value":"11",
        "id": "1"
      },
      {
        "value": true,
        "id": "4"
      }
    ],
    "targeted": false
  }
]                                                                                                                                                                                                                                                                                                      testdata/visitorsData/visitorsData5.json                                                            0000664 0001750 0001750 00000000060 14056132746 021537  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              [
  {
    "data": [],
    "targeted": true
  }
]                                                                                                                                                                                                                                                                                                                                                                                                                                                                                testdata/visitorsData/visitorsData4.json                                                            0000664 0001750 0001750 00000001277 14056132746 021551  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              [
  {
    "data": [
      {
        "value":"testKameleoon",
        "id": "1"
      }
    ],
    "targeted": true
  },
  {
    "data": [
      {
        "value":"test_kameleoon",
        "id": "1"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"test0kameleoon1",
        "id": "1"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"test_001",
        "id": "2"
      }
    ],
    "targeted": true
  },
  {
    "data": [
      {
        "value":"test_1001",
        "id": "2"
      }
    ],
    "targeted": false
  },
  {
    "data": [
      {
        "value":"test-001",
        "id": "2"
      }
    ],
    "targeted": false
  }
]                                                                                                                                                                                                                                                                                                                                 tracking.go                                                                                         0000664 0001750 0001750 00000006036 14056132746 013760  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package kameleoon

import (
	"strings"

	"development.kameleoon.net/sdk/go-sdk/types"
	"development.kameleoon.net/sdk/go-sdk/utils"
)

const (
	TrackingRequestData       = "dataTracking"
	TrackingRequestExperiment = "experimentTracking"
)

type trackingRequest struct {
	Type          string
	VisitorCode   string
	VariationID   string
	ExperimentID  int
	NoneVariation bool
}

const defaultPostMaxRetries = 10

func (c *Client) postTrackingAsync(r trackingRequest) {
	req := request{
		URL:          c.buildTrackingPath(c.Cfg.TrackingURL, r),
		Method:       MethodPost,
		ContentType:  HeaderContentTypeText,
		ClientHeader: c.Cfg.TrackingVersion,
	}
	c.m.Lock()
	req.AuthToken = c.token
	c.m.Unlock()

	data := c.selectSendData(r.VisitorCode)
	c.log("Start post to tracking: %s", data)
	var sb strings.Builder
	var err error
	for _, dataCell := range data {
		for i := 0; i < len(dataCell.Data); i++ {
			if _, exist := dataCell.Index[i]; exist {
				continue
			}
			sb.WriteString(dataCell.Data[i].QueryEncode())
			sb.WriteByte('\n')
		}
		if sb.Len() == 0 {
			continue
		}
		req.BodyString = sb.String()
		sb.Reset()
		for i := defaultPostMaxRetries; i > 0; i-- {
			err = c.rest.Do(req, nil)
			if err == nil {
				break
			}
			c.log("Trials amount left: %d, error: %v", i, err)
		}
		if err != nil {
			c.log("Failed to post tracking data, error: %v", err)
			err = nil
			continue
		}
		for i := 0; i < len(dataCell.Data); i++ {
			if _, exist := dataCell.Index[i]; exist {
				continue
			}
			dataCell.Index[i] = struct{}{}
		}
	}

	c.log("Post to tracking done")
}

func (c *Client) selectSendData(visitorCode ...string) []*types.DataCell {
	var data []*types.DataCell
	if len(visitorCode) > 0 && len(visitorCode[0]) > 0 {
		if dc := c.getDataCell(visitorCode[0]); dc != nil && len(dc.Data) != len(dc.Index) {
			data = append(data, dc)
		}
		return data
	}
	for kv := range c.Data.Iter() {
		if dc, ok := kv.Value.(*types.DataCell); ok {
			if len(dc.Data) == len(dc.Index) {
				continue
			}
			data = append(data, dc)
		}
	}
	return data
}

func (c *Client) buildTrackingPath(base string, r trackingRequest) string {
	var b strings.Builder
	switch r.Type {
	case TrackingRequestData:
		b.WriteString(base)
		b.WriteString("/dataTracking?siteCode=")
		b.WriteString(c.Cfg.SiteCode)
		b.WriteString("&visitorCode=")
		b.WriteString(r.VisitorCode)
		b.WriteString("&nonce=")
		b.WriteString(types.GetNonce())
		b.WriteString("&experimentID=")
		b.WriteString(utils.WriteUint(r.ExperimentID))
		return b.String()
	case TrackingRequestExperiment:
		b.WriteString(API_SSX_URL)
		b.WriteString("/experimentTracking?siteCode=")
		b.WriteString(c.Cfg.SiteCode)
		b.WriteString("&visitorCode=")
		b.WriteString(r.VisitorCode)
		b.WriteString("&nonce=")
		b.WriteString(types.GetNonce())
		b.WriteString("&experimentID=")
		b.WriteString(utils.WriteUint(r.ExperimentID))
		if len(r.VariationID) == 0 {
			return b.String()
		}
		b.WriteString("&variationId=")
		b.WriteString(r.VariationID)
		if r.NoneVariation {
			b.WriteString("&noneVariation=true")
		}
		return b.String()
	}
	return ""
}
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  types/                                                                                              0000775 0001750 0001750 00000000000 14056132746 012766  5                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              types/targeting.go                                                                                  0000664 0001750 0001750 00000010463 14056132746 015305  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package types

type TargetingType string

const (
	TargetingPageUrl                TargetingType = "PAGE_URL"
	TargetingPageTitle              TargetingType = "PAGE_TITLE"
	TargetingLandingPage            TargetingType = "LANDING_PAGE"
	TargetingOrigin                 TargetingType = "ORIGIN"
	TargetingOriginType             TargetingType = "ORIGIN_TYPE"
	TargetingReferrers              TargetingType = "REFERRERS"
	TargetingNewVisitors            TargetingType = "NEW_VISITORS"
	TargetingInterests              TargetingType = "INTERESTS"
	TargetingBrowserLanguage        TargetingType = "BROWSER_LANGUAGE"
	TargetingGeolocation            TargetingType = "GEOLOCATION"
	TargetingDeviceType             TargetingType = "DEVICE_TYPE"
	TargetingScreenDimension        TargetingType = "SCREEN_DIMENSION"
	TargetingVisitorIp              TargetingType = "VISITOR_IP"
	TargetingAdBlocker              TargetingType = "AD_BLOCKER"
	TargetingPreviousPage           TargetingType = "PREVIOUS_PAGE"
	TargetingKeyPages               TargetingType = "KEY_PAGES"
	TargetingPageViews              TargetingType = "PAGE_VIEWS"
	TargetingFirstVisit             TargetingType = "FIRST_VISIT"
	TargetingLastVisit              TargetingType = "LAST_VISIT"
	TargetingActiveSession          TargetingType = "ACTIVE_SESSION"
	TargetingTimeSincePageLoad      TargetingType = "TIME_SINCE_PAGE_LOAD"
	TargetingSameDayVisits          TargetingType = "SAME_DAY_VISITS"
	TargetingVisits                 TargetingType = "VISITS"
	TargetingVisitsByPage           TargetingType = "VISITS_BY_PAGE"
	TargetingInternalSearchKeywords TargetingType = "INTERNAL_SEARCH_KEYWORDS"
	TargetingTabsOnSite             TargetingType = "TABS_ON_SITE"
	TargetingConversionProbability  TargetingType = "CONVERSION_PROBABILITY"
	TargetingHeatSlice              TargetingType = "HEAT_SLICE"
	TargetingSkyStatus              TargetingType = "SKY_STATUS"
	TargetingTemperature            TargetingType = "TEMPERATURE"
	TargetingDayNight               TargetingType = "DAY_NIGHT"
	TargetingForecastSkyStatus      TargetingType = "FORECAST_SKY_STATUS"
	TargetingForecastTemperature    TargetingType = "FORECAST_TEMPERATURE"
	TargetingDayOfWeek              TargetingType = "DAY_OF_WEEK"
	TargetingTimeRange              TargetingType = "TIME_RANGE"
	TargetingHourMinuteRange        TargetingType = "HOUR_MINUTE_RANGE"
	TargetingJsCode                 TargetingType = "JS_CODE"
	TargetingCookie                 TargetingType = "COOKIE"
	TargetingEvent                  TargetingType = "EVENT"
	TargetingBrowser                TargetingType = "BROWSER"
	TargetingOperatingSystem        TargetingType = "OPERATING_SYSTEM"
	TargetingDomElement             TargetingType = "DOM_ELEMENT"
	TargetingMouseOut               TargetingType = "MOUSE_OUT"
	TargetingExperiments            TargetingType = "EXPERIMENTS"
	TargetingConversions            TargetingType = "CONVERSIONS"
	TargetingCustomDatum            TargetingType = "CUSTOM_DATUM"
	TargetingYsanceSegment          TargetingType = "YSANCE_SEGMENT"
	TargetingYsanceAttribut         TargetingType = "YSANCE_ATTRIBUT"
	TargetingTealiumBadge           TargetingType = "TEALIUM_BADGE"
	TargetingTealiumAudience        TargetingType = "TEALIUM_AUDIENCE"
	TargetingPriceOfDisplayedPage   TargetingType = "PRICE_OF_DISPLAYED_PAGE"
	TargetingNumberOfVisitedPages   TargetingType = "NUMBER_OF_VISITED_PAGES"
	TargetingVisitedPages           TargetingType = "VISITED_PAGES"
	TargetingMeanPageDuration       TargetingType = "MEAN_PAGE_DURATION"
	TargetingTimeSincePreviousVisit TargetingType = "TIME_SINCE_PREVIOUS_VISIT"
)

type TargetingConfigurationType string

const (
	TargetingConfigurationSite          TargetingConfigurationType = "SITE"
	TargetingConfigurationPage          TargetingConfigurationType = "PAGE"
	TargetingConfigurationURL           TargetingConfigurationType = "URL"
	TargetingConfigurationSavedTemplate TargetingConfigurationType = "SAVED_TEMPLATE"
)

type OperatorType string

const (
	OperatorUndefined OperatorType = "UNDEFINED"
	OperatorContains  OperatorType = "CONTAINS"
	OperatorExact     OperatorType = "EXACT"
	OperatorMatch     OperatorType = "REGULAR_EXPRESSION"
	OperatorLower     OperatorType = "LOWER"
	OperatorEqual     OperatorType = "EQUAL"
	OperatorGreater   OperatorType = "GREATER"
	OperatorIsTrue    OperatorType = "TRUE"
	OperatorIsFalse   OperatorType = "FALSE"
)
                                                                                                                                                                                                             types/experiment.go                                                                                 0000664 0001750 0001750 00000005666 14056132746 015512  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package types

import (
	"github.com/segmentio/encoding/json"
)

type ExperimentType string

const (
	ExperimentTypeClassic    ExperimentType = "CLASSIC"
	ExperimentTypeServerSide ExperimentType = "SERVER_SIDE"
	ExperimentTypeDeveloper  ExperimentType = "DEVELOPER"
	ExperimentTypeMVT        ExperimentType = "MVT"
	ExperimentTypeHybrid     ExperimentType = "HYBRID"
)

type Experiment struct {
	ID                     int                        `json:"id"`
	SiteID                 int                        `json:"siteId"`
	Name                   string                     `json:"name"`
	BaseURL                string                     `json:"baseURL"`
	Type                   ExperimentType             `json:"type"`
	Description            string                     `json:"description"`
	Tags                   []string                   `json:"tags"`
	TrackingTools          []TrackingTool             `json:"trackingTools"`
	Status                 string                     `json:"status"`
	DateCreated            TimeNoTZ                   `json:"dateCreated"`
	Goals                  []int                      `json:"goals"`
	TargetingSegmentID     int                        `json:"targetingSegmentId"`
	TargetingSegment       interface{}                `json:"-"`
	MainGoalID             int                        `json:"mainGoalId"`
	AutoOptimized          bool                       `json:"autoOptimized"`
	Deviations             Deviations                 `json:"deviations"`
	RespoolTime            RespoolTime                `json:"respoolTime"`
	TargetingConfiguration TargetingConfigurationType `json:"targetingConfiguration"`
	VariationsID           []int                      `json:"variationsId,omitempty"`
	Variations             []Variation                `json:"-"`
	DateModified           TimeNoTZ                   `json:"dateModified"`
	DateStarted            TimeNoTZ                   `json:"dateStarted"`
	DateStatusModified     TimeNoTZ                   `json:"dateStatusModified"`
	IsArchived             bool                       `json:"isArchived"`
	CreatedBy              int                        `json:"createdBy"`
	CommonCssCode          json.RawMessage            `json:"commonCssCode"`
	CommonJavaScriptCode   json.RawMessage            `json:"commonJavaScriptCode"`
}

type Deviations map[string]float64
type RespoolTime map[string]float64

type ExperimentConfig struct {
	IsEditorLaunchedByShortcut     bool              `json:"isEditorLaunchedByShortcut"`
	IsKameleoonReportingEnabled    bool              `json:"isKameleoonReportingEnabled"`
	CustomVariationSelectionScript string            `json:"customVariationSelectionScript"`
	MinWiningReliability           int               `json:"minWiningReliability"`
	AbtestConsent                  ConsentType       `json:"abtestConsent"`
	AbtestConsentOptout            ConsentOptoutType `json:"abtestConsentOptout"`
	BeforeAbtestConsent            BeforeConsentType `json:"beforeAbtestConsent"`
}
                                                                          types/data.go                                                                                       0000664 0001750 0001750 00000010110 14056132746 014217  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package types

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/segmentio/encoding/json"

	"development.kameleoon.net/sdk/go-sdk/utils"
)

type Data interface {
	QueryEncode() string
	DataType() DataType
}

type TargetingData struct {
	Data
	LastActivityTime time.Time
}

type DataCell struct {
	Data  []TargetingData
	Index map[int]struct{}
}

func (d *DataCell) MarshalJSON() ([]byte, error) {
	return json.Marshal(&d.Data)
}

func (d *DataCell) UnmarshalJSON(b []byte) error {
	return json.Unmarshal(b, &d.Data)
}

func (d *DataCell) String() string {
	b, _ := d.MarshalJSON()
	var s strings.Builder
	s.Write(b)
	return s.String()
}

const NonceLength = 16

type DataType string

const (
	DataTypeCustom     DataType = "CUSTOM"
	DataTypeBrowser    DataType = "BROWSER"
	DataTypeConversion DataType = "CONVERSION"
	DataTypeInterest   DataType = "INTEREST"
	DataTypePageView   DataType = "PAGE_VIEW"
)

func GetNonce() string {
	return utils.GetRandomString(NonceLength)
}

type EventData struct {
	Type  DataType
	Value map[string]json.RawMessage
}

func (c *EventData) UnmarshalJSON(b []byte) error {
	c.Value = make(map[string]json.RawMessage)
	err := json.Unmarshal(b, c.Value)
	if t, exist := c.Value["type"]; exist {
		delete(c.Value, "type")
		c.Type = DataType(t)
	}
	return err
}

func (c EventData) QueryEncode() string {
	var b strings.Builder
	b.WriteString("eventType=")
	b.WriteString(string(c.Type))
	b.WriteString("&nonce=")
	b.WriteString(GetNonce())
	if len(c.Value) == 0 {
		return b.String()
	}
	for k, v := range c.Value {
		b.WriteByte('&')
		b.WriteString(k)
		b.WriteByte('=')
		b.Write(v)
	}
	return b.String()
}

func (c EventData) DataType() DataType {
	return c.Type
}

type CustomData struct {
	ID    string
	Value interface{}
}

func (c CustomData) QueryEncode() string {
	var val strings.Builder
	val.WriteString(`[["`)
	val.WriteString(fmt.Sprint(c.Value))
	val.WriteString(`",1]]`)
	var b strings.Builder
	b.WriteString("eventType=customData&index=")
	b.WriteString(c.ID)
	b.WriteString("&valueToCount=")
	b.WriteString(val.String())
	b.WriteString("&overwrite=true&nonce=")
	b.WriteString(GetNonce())
	return b.String()
}

func (c CustomData) DataType() DataType {
	return DataTypeCustom
}

type BrowserType int

const (
	BrowserTypeChrome BrowserType = iota
	BrowserTypeIE
	BrowserTypeFirefox
	BrowserTypeSafari
	BrowserTypeOpera
	BrowserTypeOther
)

type Browser struct {
	Type BrowserType
}

func (b Browser) QueryEncode() string {
	var sb strings.Builder
	sb.WriteString("eventType=staticData&browser=")
	sb.WriteString(utils.WriteUint(int(b.Type)))
	sb.WriteString("&nonce=")
	sb.WriteString(GetNonce())
	return sb.String()
}

func (b Browser) DataType() DataType {
	return DataTypeBrowser
}

type PageView struct {
	URL      string
	Title    string
	Referrer int
}

func (v PageView) QueryEncode() string {
	var b strings.Builder
	b.WriteString("eventType=page&href=")
	b.WriteString(v.URL)
	b.WriteString("&title=")
	b.WriteString(v.Title)
	b.WriteString("&keyPages=[]")
	if v.Referrer == 0 {
		b.WriteString("&referrers=[")
		b.WriteString(strconv.Itoa(v.Referrer))
		b.WriteByte(']')
	}
	b.WriteString("&nonce=")
	b.WriteString(GetNonce())

	return b.String()
}

func (v PageView) DataType() DataType {
	return DataTypePageView
}

type Interest struct {
	Index int
}

func (i Interest) QueryEncode() string {
	var b strings.Builder
	b.WriteString("eventType=interests&indexes=[")
	b.WriteString(strconv.Itoa(i.Index))
	b.WriteString("]&fresh=true&nonce=")
	b.WriteString(GetNonce())
	return b.String()
}

func (i Interest) DataType() DataType {
	return DataTypeInterest
}

type Conversion struct {
	GoalID   int
	Revenue  float64
	Negative bool
}

func (c Conversion) QueryEncode() string {
	var b strings.Builder
	b.WriteString("eventType=conversion&goalId=")
	b.WriteString(utils.WriteUint(c.GoalID))
	b.WriteString("&revenue=")
	b.WriteString(strconv.FormatFloat(c.Revenue, 'f', -1, 64))
	b.WriteString("&negative=")
	b.WriteString(strconv.FormatBool(c.Negative))
	b.WriteString("&nonce=")
	b.WriteString(GetNonce())
	return b.String()
}

func (c Conversion) DataType() DataType {
	return DataTypeConversion
}
                                                                                                                                                                                                                                                                                                                                                                                                                                                        types/sdk.go                                                                                        0000664 0001750 0001750 00000000566 14056132746 014105  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package types

type SDKLanguageType string

const (
	SDKLanguageAndroid SDKLanguageType = "ANDROID"
	SDKLanguageSwift   SDKLanguageType = "SWIFT"
	SDKLanguageJava    SDKLanguageType = "JAVA"
	SDKLanguageCSharp  SDKLanguageType = "CSHARP"
	SDKLanguageNodeJS  SDKLanguageType = "NODEJS"
	SDKLanguagePHP     SDKLanguageType = "PHP"
	SDKLanguageGO      SDKLanguageType = "GO"
)
                                                                                                                                          types/tracking.go                                                                                   0000664 0001750 0001750 00000005711 14056132746 015123  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package types

type TrackingTool struct {
	Type                         TrackingToolType `json:"type"`
	CustomVariable               int              `json:"customVariable"`
	GoogleAnalyticsTracker       string           `json:"googleAnalyticsTracker"`
	UniversalAnalyticsDimension  int              `json:"universalAnalyticsDimension"`
	AdobeOmnitureObject          string           `json:"adobeOmnitureObject"`
	EulerianUserCentricParameter string           `json:"eulerianUserCentricParameter"`
	HeatMapPageWidth             int              `json:"heatMapPageWidth"`
	ComScoreCustomerID           string           `json:"comScoreCustomerId"`
	ComScoreDomain               string           `json:"comScoreDomain"`
	ReportingScript              string           `json:"reportingScript"`
}

type TrackingToolType string

const (
	TrackingToolGoogleAnalytics    TrackingToolType = "GOOGLE_ANALYTICS"
	TrackingToolUniversalAnalytics TrackingToolType = "UNIVERSAL_ANALYTICS"
	TrackingToolEconda             TrackingToolType = "ECONDA"
	TrackingToolAtInternet         TrackingToolType = "AT_INTERNET"
	TrackingToolSmartTag           TrackingToolType = "SMART_TAG"
	TrackingToolAdobeOmniture      TrackingToolType = "ADOBE_OMNITURE"
	TrackingToolEulerian           TrackingToolType = "EULERIAN"
	TrackingToolWebtrends          TrackingToolType = "WEBTRENDS"
	TrackingToolHeatmap            TrackingToolType = "HEATMAP"
	TrackingToolKissMetrics        TrackingToolType = "KISS_METRICS"
	TrackingToolPiwik              TrackingToolType = "PIWIK"
	TrackingToolCrazyEgg           TrackingToolType = "CRAZY_EGG"
	TrackingToolComScore           TrackingToolType = "COM_SCORE"
	TrackingToolTealium            TrackingToolType = "TEALIUM"
	TrackingToolYsance             TrackingToolType = "YSANCE"
	TrackingToolMPathy             TrackingToolType = "M_PATHY"
	TrackingToolMandrill           TrackingToolType = "MANDRILL"
	TrackingToolMailperformance    TrackingToolType = "MAILPERFORMANCE"
	TrackingToolSmartfocus         TrackingToolType = "SMARTFOCUS"
	TrackingToolMailjet            TrackingToolType = "MAILJET"
	TrackingToolMailup             TrackingToolType = "MAILUP"
	TrackingToolEmarsys            TrackingToolType = "EMARSYS"
	TrackingToolExpertSender       TrackingToolType = "EXPERT_SENDER"
	TrackingToolTagCommander       TrackingToolType = "TAG_COMMANDER"
	TrackingToolGoogleTagManager   TrackingToolType = "GOOGLE_TAG_MANAGER"
	TrackingToolContentSquare      TrackingToolType = "CONTENT_SQUARE"
	TrackingToolWebtrekk           TrackingToolType = "WEBTREKK"
	TrackingToolCustomIntegration  TrackingToolType = "CUSTOM_INTEGRATION"
	TrackingToolHeap               TrackingToolType = "HEAP"
	TrackingToolSegment            TrackingToolType = "SEGMENT"
	TrackingToolMixpanel           TrackingToolType = "MIXPANEL"
	TrackingToolIabtcf             TrackingToolType = "IABTCF"
	TrackingToolKameleoonTracking  TrackingToolType = "KAMELEOON_TRACKING"
	TrackingToolCustomTracking     TrackingToolType = "CUSTOM_TRACKING"
)
                                                       types/featureflag.go                                                                                0000664 0001750 0001750 00000001714 14056132746 015605  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package types

type FeatureFlag struct {
	ID                 int             `json:"id"`
	Name               string          `json:"name"`
	IdentificationKey  string          `json:"identificationKey"`
	Description        string          `json:"description"`
	Tags               []string        `json:"tags"`
	SiteID             int             `json:"siteId"`
	ExpositionRate     float64         `json:"expositionRate"`
	TargetingSegmentID int             `json:"targetingSegmentId"`
	TargetingSegment   interface{}     `json:"targetingSegment,omitempty"`
	VariationsID       []int           `json:"variationsId,omitempty"`
	Variations         []Variation     `json:"variations,omitempty"`
	Goals              []int           `json:"goals"`
	SDKLanguageType    SDKLanguageType `json:"sdkLanguageType"`
	Status             string          `json:"status"`
	DateCreated        TimeNoTZ        `json:"dateCreated"`
	DateModified       TimeNoTZ        `json:"dateModified"`
}
                                                    types/conditions.go                                                                                 0000664 0001750 0001750 00000006435 14056132746 015476  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package types

import (
	"strings"

	"github.com/segmentio/encoding/json"
)

type Condition interface {
	GetType() TargetingType
	SetType(TargetingType)
	GetInclude() bool
	SetInclude(bool)
	CheckTargeting([]TargetingData) bool
	String() string
}

type ConditionsData struct {
	FirstLevelOrOperators []bool                 `json:"firstLevelOrOperators"`
	FirstLevel            []ConditionsFirstLevel `json:"firstLevel"`
}

type ConditionsFirstLevel struct {
	OrOperators []bool               `json:"orOperators"`
	Conditions  []TargetingCondition `json:"conditions"`
}

const (
	targetingConditionStaticFieldId       = "id"
	targetingConditionStaticFieldValue    = "value"
	targetingConditionStaticFieldType     = "targetingType"
	targetingConditionStaticFieldOperator = "valueMatchType"
	targetingConditionStaticFieldWeight   = "weight"
	targetingConditionStaticFieldIndex    = "customDataIndex"
	targetingConditionStaticFieldInclude  = "include"
)

var targetingConditionStaticFields = [...]string{targetingConditionStaticFieldId, targetingConditionStaticFieldValue,
	targetingConditionStaticFieldType, targetingConditionStaticFieldOperator, targetingConditionStaticFieldWeight,
	targetingConditionStaticFieldIndex, targetingConditionStaticFieldInclude}

type TargetingCondition struct {
	Rest     map[string]json.RawMessage `json:"-"`
	Value    interface{}                `json:"value,omitempty"`
	Type     TargetingType              `json:"targetingType"`
	Operator OperatorType               `json:"valueMatchType,omitempty"`
	Index    string                     `json:"customDataIndex,omitempty"`
	ID       int                        `json:"id"`
	Weight   int                        `json:"weight,omitempty"`
	Include  *bool                      `json:"include,omitempty"`
}

func (c *TargetingCondition) UnmarshalJSON(b []byte) error {
	c.Rest = make(map[string]json.RawMessage)
	if err := json.Unmarshal(b, &c.Rest); err != nil {
		return err
	}
	var value json.RawMessage
	var exist bool
	var err error
	for _, field := range targetingConditionStaticFields {
		value, exist = c.Rest[field]
		if !exist {
			continue
		}
		delete(c.Rest, field)
		switch field {
		case targetingConditionStaticFieldType:
			err = json.Unmarshal(value, &c.Type)
		case targetingConditionStaticFieldId:
			err = json.Unmarshal(value, &c.ID)
		case targetingConditionStaticFieldValue:
			err = json.Unmarshal(value, &c.Value)
		case targetingConditionStaticFieldOperator:
			err = json.Unmarshal(value, &c.Operator)
		case targetingConditionStaticFieldWeight:
			err = json.Unmarshal(value, &c.Weight)
		case targetingConditionStaticFieldIndex:
			err = json.Unmarshal(value, &c.Index)
		case targetingConditionStaticFieldInclude:
			err = json.Unmarshal(value, &c.Include)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func (c *TargetingCondition) String() string {
	var s strings.Builder
	b, _ := json.Marshal(c)
	s.Write(b)
	return s.String()
}

func (c TargetingCondition) GetType() TargetingType {
	return c.Type
}

func (c *TargetingCondition) SetType(tt TargetingType) {
	c.Type = tt
}

func (c TargetingCondition) GetInclude() bool {
	if c.Include == nil {
		return true
	}
	return *c.Include
}

func (c *TargetingCondition) SetInclude(i bool) {
	c.Include = &i
}

func (c TargetingCondition) CheckTargeting(_ []TargetingData) bool {
	return true
}
                                                                                                                                                                                                                                   types/audience.go                                                                                   0000664 0001750 0001750 00000004071 14056132746 015074  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package types

type URLMatchType string

const (
	URLMatchExact             URLMatchType = "EXACT"
	URLMatchContains          URLMatchType = "CONTAINS"
	URLMatchRegularExpression URLMatchType = "REGULAR_EXPRESSION"
	URLMatchTargetedUrl       URLMatchType = "TARGETED_URL"
)

type AudienceConfigURL struct {
	URL       string       `json:"url"`
	MatchType URLMatchType `json:"matchType"`
}

type SiteType string

const (
	SiteTypeEcommerce SiteType = "ECOMMERCE"
	SiteTypeMedia     SiteType = "MEDIA"
	SiteTypeOther     SiteType = "OTHER"
)

type AudienceConfig struct {
	MainGoal                     int                 `json:"mainGoal"`
	IncludedTargetingTypeList    []TargetingType     `json:"includedTargetingTypeList"`
	ExcludedTargetingTypeList    []TargetingType     `json:"excludedTargetingTypeList"`
	IncludedConfigurationUrlList []AudienceConfigURL `json:"includedConfigurationUrlList"`
	ExcludedConfigurationUrlList []AudienceConfigURL `json:"excludedConfigurationUrlList"`
	IncludedCustomData           []string            `json:"includedCustomData"`
	ExcludedCustomData           []string            `json:"excludedCustomData"`
	IncludedTargetingSegmentList []string            `json:"includedTargetingSegmentList"`
	ExcludedTargetingSegmentList []string            `json:"excludedTargetingSegmentList"`
	SiteType                     SiteType            `json:"siteType"`
	IgnoreURLSettings            bool                `json:"ignoreURLSettings"`
	PredictiveTargeting          bool                `json:"predictiveTargeting"`
	ExcludedGoalList             []string            `json:"excludedGoalList"`
	IncludedExperimentList       []string            `json:"includedExperimentList"`
	ExcludedExperimentList       []string            `json:"excludedExperimentList"`
	IncludedPersonalizationList  []string            `json:"includedPersonalizationList"`
	ExcludedPersonalizationList  []string            `json:"excludedPersonalizationList"`
	CartAmountGoal               int                 `json:"cartAmountGoal"`
	CartAmountValue              int                 `json:"cartAmountValue"`
}
                                                                                                                                                                                                                                                                                                                                                                                                                                                                       types/types.go                                                                                      0000664 0001750 0001750 00000007233 14056132746 014466  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package types

import (
	"time"
)

type WhenTimeoutType string

const (
	WhenTimeoutRun             WhenTimeoutType = "RUN"
	WhenTimeoutDisableForPage  WhenTimeoutType = "DISABLE_FOR_PAGE"
	WhenTimeoutDisableForVisit WhenTimeoutType = "DISABLE_FOR_VISIT"
)

type DataStorageType string

const (
	DataStorageStandardCookie DataStorageType = "STANDARD_COOKIE"
	DataStorageLocalStorage   DataStorageType = "LOCAL_STORAGE"
	DataStorageCustomCookie   DataStorageType = "CUSTOM_COOKIE"
)

type IndicatorType string

const (
	IndicatorsRetentionRate     IndicatorType = "RETENTION_RATE"
	IndicatorsNumberOfPagesSeen IndicatorType = "NUMBER_OF_PAGES_SEEN"
	IndicatorsDwellTime         IndicatorType = "DWELL_TIME"
)

type EventMethodType string

const (
	EventMethodClick     EventMethodType = "CLICK"
	EventMethodMousedown EventMethodType = "MOUSEDOWN"
	EventMethodMouseup   EventMethodType = "MOUSEUP"
)

type SiteResponse struct {
	ID                  int                   `json:"id"`
	URL                 string                `json:"url"`
	Description         string                `json:"description"`
	Code                string                `json:"code"`
	BehaviorWhenTimeout WhenTimeoutType       `json:"behaviorWhenTimeout"`
	DataStorage         DataStorageType       `json:"dataStorage"`
	TrackingScript      string                `json:"trackingScript"`
	DomainNames         []string              `json:"domainNames"`
	Indicators          []IndicatorType       `json:"indicators"`
	DateCreated         TimeNoTZ              `json:"dateCreated"`
	IsScriptActive      bool                  `json:"isScriptActive"`
	CaptureEventMethod  EventMethodType       `json:"captureEventMethod"`
	IsAudienceUsed      bool                  `json:"isAudienceUsed"`
	IsKameleoonEnabled  bool                  `json:"isKameleoonEnabled"`
	Experiment          ExperimentConfig      `json:"experimentConfig"`
	Personalization     PersonalizationConfig `json:"personalizationConfig"`
	Audience            AudienceConfig        `json:"audienceConfig"`
}

type ConsentType string

const (
	ConsentOff         ConsentType = "OFF"
	ConsentRequired    ConsentType = "REQUIRED"
	ConsentInteractive ConsentType = "INTERACTIVE"
	ConsentIABTCF      ConsentType = "IABTCF"
)

type ConsentOptoutType string

const (
	ConsentOptoutRun   ConsentOptoutType = "RUN"
	ConsentOptoutBlock ConsentOptoutType = "BLOCK"
)

type BeforeConsentType string

const (
	BeforeConsentNone      BeforeConsentType = "NONE"
	BeforeConsentPartially BeforeConsentType = "PARTIALLY"
	BeforeConsentAll       BeforeConsentType = "ALL"
)

type PersonalizationConfig struct {
	PersonalizationsDeviation        float64           `json:"personalizationsDeviation"`
	IsSameTypePersonalizationEnabled bool              `json:"isSameTypePersonalizationEnabled"`
	IsSameJqueryInjectionAllowed     bool              `json:"isSameJqueryInjectionAllowed"`
	PersonalizationConsent           ConsentType       `json:"personalizationConsent"`
	PersonalizationConsentOptout     ConsentOptoutType `json:"personalizationConsentOptout"`
	BeforePersonalizationConsent     BeforeConsentType `json:"beforePersonalizationConsent"`
}

type TimeNoTZ time.Time

const TimeNoTZLayout = `"2006-01-02T15:04:05"`

// UnmarshalJSON Parses the json string in the custom format
func (t *TimeNoTZ) UnmarshalJSON(date []byte) error {
	nt, err := time.Parse(TimeNoTZLayout, string(date))
	*t = TimeNoTZ(nt)
	return err
}

// MarshalJSON writes a quoted string in the custom format
func (t TimeNoTZ) MarshalJSON() ([]byte, error) {
	return time.Time(t).AppendFormat(nil, TimeNoTZLayout), nil
}

// String returns the time in the custom format
func (t TimeNoTZ) String() string {
	return time.Time(t).Format(TimeNoTZLayout)
}
                                                                                                                                                                                                                                                                                                                                                                     types/variation.go                                                                                  0000664 0001750 0001750 00000002447 14056132746 015320  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package types

import "github.com/segmentio/encoding/json"

type Variation struct {
	ID                    int                  `json:"id"`
	SiteID                int                  `json:"siteId"`
	Name                  string               `json:"name"`
	JsCode                json.RawMessage      `json:"jsCode"`
	CssCode               json.RawMessage      `json:"cssCode"`
	IsJsCodeAfterDomReady bool                 `json:"isJsCodeAfterDomReady"`
	WidgetTemplateInput   json.RawMessage      `json:"widgetTemplateInput"`
	RedirectionStrings    string               `json:"redirectionStrings"`
	Redirection           VariationRedirection `json:"redirection"`
	ExperimentID          int                  `json:"experimentId"`
	CustomJson            json.RawMessage      `json:"customJson"`
}

type VariationRedirectionType string

const (
	VariationRedirectionGlobal    VariationRedirectionType = "GLOBAL_REDIRECTION"
	VariationRedirectionParameter VariationRedirectionType = "PARAMETER_REDIRECTION"
)

type VariationRedirection struct {
	Type                   VariationRedirectionType `json:"type"`
	Url                    string                   `json:"url"`
	Parameters             string                   `json:"parameters"`
	IncludeQueryParameters bool                     `json:"includeQueryParameters"`
}
                                                                                                                                                                                                                         types/segment.go                                                                                    0000664 0001750 0001750 00000002015 14056132746 014755  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package types

type Segment struct {
	ID                       int             `json:"id"`
	Name                     string          `json:"name"`
	Description              string          `json:"description"`
	ConditionsData           *ConditionsData `json:"conditionsData"`
	SiteID                   int             `json:"siteId"`
	AudienceTracking         bool            `json:"audienceTracking"`
	AudienceTrackingEditable bool            `json:"audienceTrackingEditable"`
	IsFavorite               bool            `json:"isFavorite"`
	DateCreated              TimeNoTZ        `json:"dateCreated"`
	DateModified             TimeNoTZ        `json:"dateModified"`
	Tags                     []string        `json:"tags"`
	ExperimentAmount         int             `json:"experimentAmount,omitempty"`
	PersonalizationAmount    int             `json:"personalizationAmount,omitempty"`
	ExperimentIds            []string        `json:"experiments,omitempty"`
	PersonalizationIds       []string        `json:"personalizations,omitempty"`
}
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   utils/                                                                                              0000775 0001750 0001750 00000000000 14056132746 012762  5                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              utils/rand.go                                                                                       0000664 0001750 0001750 00000001437 14056132746 014242  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package utils

import (
	"math/rand"
	"strings"
)

const letterBytes = "abcdef0123456789"
const (
	letterIdxBits = 6                    // 6 bits to represent a letter index
	letterIdxMask = 1<<letterIdxBits - 1 // All 1-bits, as many as letterIdxBits
	letterIdxMax  = 63 / letterIdxBits   // # of letter indices fitting in 63 bits
)

func GetRandomString(n int) string {
	sb := strings.Builder{}
	sb.Grow(n)
	// A src.Int63() generates 63 random bits, enough for letterIdxMax characters!
	for i, cache, remain := n-1, rand.Int63(), letterIdxMax; i >= 0; {
		if remain == 0 {
			cache, remain = rand.Int63(), letterIdxMax
		}
		if idx := int(cache & letterIdxMask); idx < len(letterBytes) {
			sb.WriteByte(letterBytes[idx])
			i--
		}
		cache >>= letterIdxBits
		remain--
	}

	return sb.String()
}
                                                                                                                                                                                                                                 utils/parse.go                                                                                      0000664 0001750 0001750 00000002276 14056132746 014432  0                                                                                                    ustar   guillaume                       guillaume                                                                                                                                                                                                              package utils

import (
	"errors"
	"strings"
)

// ParseUint parses uint from buf.
func ParseUint(buf string) (int, error) {
	v, n, err := parseUintBuf(buf)
	if n != len(buf) {
		return -1, errUnexpectedTrailingChar
	}
	return v, err
}

var (
	errEmptyInt               = errors.New("empty integer")
	errUnexpectedFirstChar    = errors.New("unexpected first char found. Expecting 0-9")
	errUnexpectedTrailingChar = errors.New("unexpected trailing char found. Expecting 0-9")
	errTooLongInt             = errors.New("too long int")
)

func parseUintBuf(b string) (int, int, error) {
	n := len(b)
	if n == 0 {
		return -1, 0, errEmptyInt
	}
	v := 0
	for i := 0; i < n; i++ {
		c := b[i]
		k := c - '0'
		if k > 9 {
			if i == 0 {
				return -1, i, errUnexpectedFirstChar
			}
			return v, i, nil
		}
		vNew := 10*v + int(k)
		// Test for overflow.
		if vNew < v {
			return -1, i, errTooLongInt
		}
		v = vNew
	}
	return v, n, nil
}

func WriteUint(n int) string {
	if n < 0 {
		return ""
	}

	var b [20]byte
	buf := b[:]
	i := len(buf)
	var q int
	for n >= 10 {
		i--
		q = n / 10
		buf[i] = '0' + byte(n-q*10)
		n = q
	}
	i--
	buf[i] = '0' + byte(n)

	var s strings.Builder
	s.Write(buf[i:])
	return s.String()
}

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  
