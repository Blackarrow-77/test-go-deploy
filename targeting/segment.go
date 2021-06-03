package targeting

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
