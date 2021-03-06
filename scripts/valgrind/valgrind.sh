#!/bin/bash
set -e
set -x
SCRIPTS_DIR="$(readlink -f $(dirname $0)/../..)"

if [ -z "$REVISION" ]; then
    export REVISION="default"
fi

if [ -z "$HG_REPO" ]; then
    export HG_REPO="http://hg.mozilla.org/mozilla-central"
fi

if [ -f "$PROPERTIES_FILE" ]; then
    PYTHON="/tools/python/bin/python"
    [ -x $PYTHON ] || PYTHON=python
    JSONTOOL="$PYTHON $SCRIPTS_DIR/buildfarm/utils/jsontool.py"

    builder=$($JSONTOOL -k properties.buildername $PROPERTIES_FILE)
    slavename=$($JSONTOOL -k properties.slavename $PROPERTIES_FILE)
    master=$($JSONTOOL -k properties.master $PROPERTIES_FILE)

    builddir=$(basename $(readlink -f .))
    branch=$(basename $HG_REPO)

    # Clobbering
    if [ -z "$CLOBBERER_URL" ]; then
        export CLOBBERER_URL="http://clobberer.pvt.build.mozilla.org/index.php"
    fi

    cd $SCRIPTS_DIR/../..
    python $SCRIPTS_DIR/clobberer/clobberer.py -s scripts -s $(basename $PROPERTIES_FILE) \
        $CLOBBERER_URL $branch "$builder" $builddir $slavename $master

    # Purging
    cd $SCRIPTS_DIR/..
    python $SCRIPTS_DIR/buildfarm/maintenance/purge_builds.py \
        -s 8 -n info -n 'rel-*' -n 'tb-rel-*' -n $builddir
fi

python $SCRIPTS_DIR/buildfarm/utils/hgtool.py --rev $REVISION $HG_REPO src || exit 2

# Put our short revisions into the properties directory for consumption by buildbot.
if [ ! -d properties ]; then
    mkdir properties
fi
pushd src; GOT_REVISION=`hg parent --template={node} | cut -c1-12`; popd
echo "revision: $GOT_REVISION" > properties/revision
echo "got_revision: $GOT_REVISION" > properties/got_revision

if [ ! -d objdir ]; then
    mkdir objdir
fi
cd objdir

export G_SLICE=always-malloc

if [ "`uname -m`" = "x86_64" ]; then
    export LD_LIBRARY_PATH=/tools/gcc-4.5-0moz3/installed/lib64
    _arch=64
else
    export LD_LIBRARY_PATH=/tools/gcc-4.5-0moz3/installed/lib
    _arch=32
fi

MOZCONFIG=../src/browser/config/mozconfigs/linux${_arch}/valgrind make -f ../src/client.mk configure || exit 2
make -j4 || exit 2
make package || exit 2

debugger_args="--error-exitcode=1 --smc-check=all-non-file --gen-suppressions=all --leak-check=full --num-callers=50 --show-possibly-lost=no --track-origins=yes"
cross_architecture_suppression_file=$PWD/_valgrind/cross-architecture.sup
if [ -f $cross_architecture_suppression_file ]; then
    debugger_args="$debugger_args --suppressions=$cross_architecture_suppression_file"
fi
suppression_file=$PWD/_valgrind/${MACHTYPE}.sup
if [ -f $suppression_file ]; then
    debugger_args="$debugger_args --suppressions=$suppression_file"
fi

export OBJDIR=.
export JARLOG_FILE=./jarlog/en-US.log
export XPCOM_CC_RUN_DURING_SHUTDOWN=1
make pgo-profile-run EXTRA_TEST_ARGS="--debugger=valgrind --debugger-args='$debugger_args'" || exit 1
