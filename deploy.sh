#!/bin/sh
# deploy - push selected files to github

deploy_directory="test-go-deploy"
github_account_name="Blackarrow-77"


echo "Prepare for deployment"
# Init github repository inside deploy folder
rm -rf "${deploy_directory}"

# Clone git and get version
git clone "git@github.com:${github_account_name}/${deploy_directory}.git"
cd ${deploy_directory}
version=$(echo $(git describe --tags) | perl -ne 'chomp; print join(".", splice(@{[split/\./,$_]}, 0, -1), map {++$_} pop @{[split/\./,$_]}), "\n";')
while [ "$1" != "" ]; do
    case $1 in
    -v | --version)
        version=$2
        ;;
    esac
    shift
done
cd ../
rm -rf "${deploy_directory}"/*

# Copy needed files for deploy into a directory
tar cf deploy.tar --exclude="${deploy_directory}" *
mv deploy.tar "${deploy_directory}"/deploy.tar
cd "${deploy_directory}"
tar xf deploy.tar
rm deploy.tar
find . -name "*test*" -type f -delete
rm -rf *test*

echo "Deploying version ${version}"

# Commit and push new files
git add *
git commit -m "Version ${version}"
git push --force

# Create tag and push
git tag "${version}" master
git push origin "${version}"

# Remove deploy folder
cd ../
rm -rf "${deploy_directory}"

echo "Finished to deploy version ${version}"
