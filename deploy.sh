#!/bin/sh
# deploy - push selected files to github

deploy_directory="test-go-deploy"
github_account_name="Blackarrow-77"

version=$(echo $(git describe --tags) | awk -F. -v OFS=. '{$NF++;print}')
while [ "$1" != "" ]; do
    case $1 in
    -v | --version)
        version=$2
        ;;
    esac
    shift
done

echo "Deploying version ${version}"

# Init github repository inside deploy folder
rm -rf "${deploy_directory}"

git clone "git@github.com:${github_account_name}/${deploy_directory}.git"
rm -rf "${deploy_directory}"/*

# Copy needed files for deploy into a directory
tar cvf deploy.tar --exclude="${deploy_directory}" *
mv deploy.tar "${deploy_directory}"/deploy.tar
cd "${deploy_directory}"
tar xvf deploy.tar
rm deploy.tar
find . -name "*test*" -type f -delete
rm -rf *test*

# Commit and push new files
git add *
git commit -m "Version ${version}"
git push --force

# Create tag and push
git tag "${version}" master
git push origin "${version}"

echo "Finished to deploy version ${version}"
