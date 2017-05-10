#!/bin/bash

## This script must run with an ssh key for openshift-bot loaded.

set -o xtrace

echo
echo "=========="
echo "Making sure we have kerberos"
echo "=========="
kinit -k -t /home/jenkins/ocp-build.keytab ocp-build/atomic-e2e-jenkins.rhev-ci-vms.eng.rdu2.redhat.com@REDHAT.COM

# Path for merge-and-build script
MB_PATH=$(readlink -f $0)

set -o errexit
set -o nounset
set -o pipefail

if [ "$#" -ne 2 ]; then
  echo "Please pass in MAJOR and MINOR version"
  exit 1
else
  MAJOR="$1"
  MINOR="$2"
fi

OSE_VERSION="${MAJOR}.${MINOR}"
PUSH_EXTRA=""

if [ "${OSE_VERSION}" != "${OSE_MASTER}" ] ; then
  if [ "$BUILD_MODE" != "enterprise" ]; then
    echo "Unable to build old version ($OSE_VERSION) in online mode when master contains: $OSE_MASTER"
    exit 1
  fi
  PUSH_EXTRA="--nolatest"
fi

if [ -z "$WORKSPACE" ]; then
    echo "WORKSPACE environment variable has not been set. Aborting."
    exit 1
fi

# Use the directory relative to this Jenkins job.
BUILDPATH="${WORKSPACE}"

if [ -d "${BUILDPATH}/src" ]; then
    rm -rf "${BUILDPATH}/src" # Remove any previous clone
fi

RESULTS="${BUILDPATH}/results"
if [ -d "${RESULTS}" ]; then
    rm -rf "${RESULTS}"
fi
mkdir -p "${RESULTS}"

WORKPATH="${BUILDPATH}/src/github.com/openshift/"
mkdir -p ${WORKPATH}
cd ${BUILDPATH}
export GOPATH="$( pwd )"
echo "GOPATH: ${GOPATH}"
echo "BUILDPATH: ${BUILDPATH}"
echo "WORKPATH ${WORKPATH}"
echo "BUILD_MODE ${BUILD_MODE}"

go get github.com/jteeuwen/go-bindata

if [ "${OSE_VERSION}" == "3.2" ] ; then
  echo
  echo "=========="
  echo "OCP 3.2 builds will not work in this build environment."
  echo "We are exiting now to save you problems later."
  echo "Exiting ..."
  exit 1
fi # End check if we are version 3.2

echo
echo "=========="
echo "Setup: openshift-ansible"
echo "=========="
rm -rf openshift-ansible
git clone git@github.com:openshift/openshift-ansible.git
cd openshift-ansible/
if [ "${BUILD_MODE}" == "online:stg" ] ; then
    git checkout -q stage
else
  if [ "${OSE_VERSION}" != "${OSE_MASTER}" ] ; then
    if [ "${MAJOR}" -eq 3 -a "${MINOR}" -le 5 ] ; then # 3.5 and below maps to "release-1.5"
      git checkout -q release-1.${MINOR}
    else  # Afterwards, version maps directly; 3.5 => "release-3.5"
      git checkout -q release-${OSE_VERSION}
    fi
  fi
fi

echo
echo "=========="
echo "Tito Tagging: openshift-ansible"
echo "=========="
tito tag --accept-auto-changelog
git push
git push --tags

echo
echo "=========="
echo "Tito building in brew: openshift-ansible"
echo "=========="
TASK_NUMBER=`tito release --yes --test aos-${OSE_VERSION} | grep 'Created task:' | awk '{print $3}'`
echo "TASK NUMBER: ${TASK_NUMBER}"
echo "TASK URL: https://brewweb.engineering.redhat.com/brew/taskinfo?taskID=${TASK_NUMBER}"
echo
echo -n "https://brewweb.engineering.redhat.com/brew/taskinfo?taskID=${TASK_NUMBER}" > "${RESULTS}/openshift-ansible-brew.url"
brew watch-task ${TASK_NUMBER}

echo
echo "=========="
echo "Setup origin-web-console stuff"
echo "=========="
cd ${WORKPATH}
rm -rf origin-web-console
git clone git@github.com:openshift/origin-web-console.git
cd origin-web-console/
if [ "${BUILD_MODE}" == "online:stg" ] ; then
  git checkout stage
else
  git checkout enterprise-${OSE_VERSION}
  if [ "${OSE_VERSION}" == "${OSE_MASTER}" ] ; then
    git merge master -m "Merge master into enterprise-${OSE_VERSION}"
    git push
  fi
fi

echo
echo "=========="
echo "Setup ose stuff"
echo "=========="
cd ${WORKPATH}
rm -rf ose
git clone git@github.com:openshift/ose.git
cd ose

# Enable fake merge driver used in our .gitattributes
# https://github.com/openshift/ose/commit/02b57ed38d94ba1d28b9bc8bd8abcb6590013b7c
git config merge.ours.driver true

if [ "${BUILD_MODE}" == "enterprise" ]; then

  git checkout -q enterprise-${OSE_VERSION}

else

  # If we are here, we are building master or stage for online

  if [ "${BUILD_MODE}" == "online:stg" ] ; then
    CURRENT_BRANCH="stage"
    UPSTREAM_BRANCH="upstream/stage"
  elif [ "${BUILD_MODE}" == "enterprise:pre-release" ] ; then
    CURRENT_BRANCH="enterprise-${OSE_VERSION}"
    UPSTREAM_BRANCH="upstream/release-${OSE_VERSION}"
  else # Otherwise, online:int
    CURRENT_BRANCH="master"
    UPSTREAM_BRANCH="upstream/master"
  fi

  echo "Building from branch: ${CURRENT_BRANCH}"
  git checkout -q ${CURRENT_BRANCH}

  git remote add upstream git@github.com:openshift/origin.git --no-tags
  git fetch --all


  echo
  echo "=========="
  echo "Merge origin into ose stuff"
  echo "=========="
  git merge -m "Merge remote-tracking branch ${UPSTREAM_BRANCH}" ${UPSTREAM_BRANCH}

fi

echo
echo "=========="
echo "Merge in origin-web-console stuff"
echo "=========="
VC_COMMIT="$(GIT_REF=enterprise-${OSE_VERSION} hack/vendor-console.sh 2>/dev/null | grep "Vendoring origin-web-console" | awk '{print $4}')"
git add pkg/assets/bindata.go
git add pkg/assets/java/bindata.go
set +e # Temporarily turn off errexit. THis is failing sometimes. Check with Troy if it is expected.
if [ "${BUILD_MODE}" == "online:stg" ] ; then
  git commit -m "Merge remote-tracking branch stage, bump origin-web-console ${VC_COMMIT}"
else  
  git commit -m "Merge remote-tracking branch enterprise-${OSE_VERSION}, bump origin-web-console ${VC_COMMIT}"
fi
set -e

# Put local rpm testing here

echo
echo "=========="
echo "Tito Tagging"
echo "=========="
tito tag --accept-auto-changelog
export VERSION="v$(grep Version: origin.spec | awk '{print $2}')"
echo ${VERSION}
git push
git push --tags

echo
echo "=========="
echo "Tito building in brew"
echo "=========="
TASK_NUMBER=`tito release --yes --test aos-${OSE_VERSION} | grep 'Created task:' | awk '{print $3}'`
echo "TASK NUMBER: ${TASK_NUMBER}"
echo "TASK URL: https://brewweb.engineering.redhat.com/brew/taskinfo?taskID=${TASK_NUMBER}"
echo
echo -n "https://brewweb.engineering.redhat.com/brew/taskinfo?taskID=${TASK_NUMBER}" > "${RESULTS}/ose-brew.url"
brew watch-task ${TASK_NUMBER}

echo
echo "=========="
echo "Building Puddle"
echo "=========="
ssh ocp-build@rcm-guest.app.eng.bos.redhat.com "puddle -b -d /mnt/rcm-guest/puddles/RHAOS/conf/atomic_openshift-${OSE_VERSION}.conf -n -s --label=building"

# If we are at the stage mode, dont be messing with the dist-git checking
if [ "${BUILD_MODE}" != "online:stg" ] ; then
  echo
  echo "=========="
  echo "Sync git to dist-git repos"
  echo "=========="
  ose_images.sh --user ocp-build compare_nodocker --branch rhaos-${OSE_VERSION}-rhel-7 --group base
fi # End check for stg

echo
echo "=========="
echo "Update Dockerfiles to new version"
echo "=========="
ose_images.sh --user ocp-build update_docker --branch rhaos-${OSE_VERSION}-rhel-7 --group base --force --release 1 --version ${VERSION}

echo
echo "=========="
echo "Build Images"
echo "=========="
ose_images.sh --user ocp-build build_container --branch rhaos-${OSE_VERSION}-rhel-7 --group base --repo http://download.lab.bos.redhat.com/rcm-guest/puddles/RHAOS/repos/aos-unsigned-building.repo

echo
echo "=========="
echo "Push Images"
echo "=========="
sudo ose_images.sh --user ocp-build push_images ${PUSH_EXTRA} --branch rhaos-${OSE_VERSION}-rhel-7 --group base

echo
echo "=========="
echo "Create latest puddle"
echo "=========="
ssh ocp-build@rcm-guest.app.eng.bos.redhat.com "puddle -n -b -d /mnt/rcm-guest/puddles/RHAOS/conf/atomic_openshift-${OSE_VERSION}.conf"
# Record the name of the puddle which was created
PUDDLE_NAME=$(ssh ocp-build@rcm-guest.app.eng.bos.redhat.com readlink "/mnt/rcm-guest/puddles/RHAOS/AtomicOpenShift/${OSE_VERSION}/latest")
echo -n "${PUDDLE_NAME}" > "${RESULTS}/ose-puddle.name"
echo "Created puddle on rcm-guest: /mnt/rcm-guest/puddles/RHAOS/AtomicOpenShift/$OSE_VERSION}/${PUDDLE_NAME}"

echo
echo "=========="
echo "Sync latest puddle to mirrors"
echo "=========="
case "${BUILD_MODE}" in
online:int ) ssh ocp-build@rcm-guest.app.eng.bos.redhat.com " /mnt/rcm-guest/puddles/RHAOS/scripts/push-to-mirrors.sh simple ${OSE_VERSION} online-int" ;;
online:stg ) ssh ocp-build@rcm-guest.app.eng.bos.redhat.com " /mnt/rcm-guest/puddles/RHAOS/scripts/push-to-mirrors.sh simple ${OSE_VERSION} online-stg" ;;
enterprise ) ssh ocp-build@rcm-guest.app.eng.bos.redhat.com " /mnt/rcm-guest/puddles/RHAOS/scripts/push-to-mirrors.sh simple ${OSE_VERSION}" ;;
enterprise:pre-release ) ssh ocp-build@rcm-guest.app.eng.bos.redhat.com " /mnt/rcm-guest/puddles/RHAOS/scripts/push-to-mirrors.sh simple ${OSE_VERSION}" ;;
* ) echo "BUILD_MODE:${BUILD_MODE} did not match anything we know about, not pushing"
esac


echo
echo "=========="
echo "Publish the oc binary"
echo "=========="
ssh ocp-build@rcm-guest.app.eng.bos.redhat.com \
    sh -s "$OSE_VERSION" "${VERSION#v}" \
    < "$WORKSPACE/build-scripts/rcm-guest/publish-oc-binary.sh"
for x in "${VERSION#v}/"{linux/oc.tar.gz,macosx/oc.tar.gz,windows/oc.zip}; do
    curl --silent --show-error --head \
        "https://mirror.openshift.com/pub/openshift-v3/clients/$x" \
        | awk '$2!="200"{print > "/dev/stderr"; exit 1}{exit}'
done

echo
echo
echo "=========="
echo "Finished"
echo "OCP ${VERSION}"
echo "=========="
