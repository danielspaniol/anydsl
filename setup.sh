#!/usr/bin/env bash
set -eu

COLOR_RED="\033[0;31m"
COLOR_RESET="\033[0m"

echo ">>> update setup project"
git fetch origin --recurse-submodules=yes
git submodule update --init --recursive

UPSTREAM=${1:-'@{u}'}
LOCAL=$(git rev-parse @)
REMOTE=$(git rev-parse "$UPSTREAM")
BASE=$(git merge-base @ "$UPSTREAM")

function red_echo {
    echo -e "${COLOR_RED}!!! $1${COLOR_RESET}"
}

function mkdir_cd {
    mkdir -p $1
    cd $1
}

if [ $LOCAL = $REMOTE ]; then
    red_echo "your branch is up-to-date"
elif [ $LOCAL = $BASE ]; then
    red_echo "your branch is behind your tracking branch"
    red_echo "I pull and rerun the script "
    git pull --recurse-submodules=yes
    ./$0
    exit $?
elif [ $REMOTE = $BASE ]; then
    red_echo "your branch is ahead of your tracking branch"
    red_echo "remember to push your changes but I will run the script anyway"
else
    red_echo "your branch and your tracking remote branch have diverged"
    red_echo "resolve all conflicts before rerunning the script"
    exit 1
fi

if [ ! -e config.sh ]; then
    red_echo "first configure your build:"
    red_echo "cp config.sh.template config.sh"
    red_echo "edit config.sh"
    exit -1
fi

source config.sh

CUR=`pwd`

function clone_or_update {
    branch=${3:-master}
    if [ ! -e "$2" ]; then
        echo -e ">>> clone $1/$2 $COLOR_RED($branch)$COLOR_RESET"
        git clone --recursive `https://github.com/$1/$2.git` --branch $branch
    else
        cd $2
        echo -e ">>> pull $1/$2 $COLOR_RED($branch)$COLOR_RESET"
        git fetch --tags origin
        git checkout --recurse-submodules $branch
        set +e
        git symbolic-ref HEAD
        if [ $? -eq 0 ]; then
            git pull
        fi
        set -e
        cd ..
    fi
}

# fetch sources
if [ "${LLVM-}" == true ] ; then
    mkdir -p llvm_build/

    if [ ! -e  "${CUR}/llvm" ]; then
        wget http://releases.llvm.org/6.0.1/llvm-6.0.1.src.tar.xz
        tar xf llvm-6.0.1.src.tar.xz
        rm llvm-6.0.1.src.tar.xz
        mv llvm-6.0.1.src llvm
        cd llvm/tools
        wget http://releases.llvm.org/6.0.1/cfe-6.0.1.src.tar.xz
        wget http://releases.llvm.org/6.0.1/lld-6.0.1.src.tar.xz
        tar xf cfe-6.0.1.src.tar.xz
        tar xf lld-6.0.1.src.tar.xz
        rm cfe-6.0.1.src.tar.xz
        rm lld-6.0.1.src.tar.xz
        mv cfe-6.0.1.src clang
        mv lld-6.0.1.src lld
    fi

    # rv
    cd "${CUR}"
    cd llvm/tools
    clone_or_update cdl-saarland rv ${BRANCH_RV}
    mkdir -p rv/build/
    cd "${CUR}"

    # build llvm
    cd llvm_build
    cmake ../llvm ${CMAKE_MAKE} -DBUILD_SHARED_LIBS:BOOL=ON -DCMAKE_BUILD_TYPE:STRING=${BUILD_TYPE} -DCMAKE_INSTALL_PREFIX:PATH="${CUR}/llvm_install" \
        -DLLVM_ENABLE_RTTI:BOOL=ON -DLLVM_ENABLE_CXX1Y:BOOL=ON -DLLVM_INCLUDE_TESTS:BOOL=ON -DLLVM_TARGETS_TO_BUILD:STRING="${LLVM_TARGETS}"
    ${MAKE} install
    cd "${CUR}"

    LLVM_VARS=-DLLVM_DIR:PATH="${CUR}/llvm_install/lib/cmake/llvm"
else
    LLVM_VARS=-DCMAKE_DISABLE_FIND_PACKAGE_LLVM=TRUE
fi

# source this file to put clang and impala in path
cat > "${CUR}/project.sh" <<_EOF_
export PATH="${CUR}/llvm_install/bin:${CUR}/impala/build/bin:\${PATH:-}"
export LD_LIBRARY_PATH="${CUR}/llvm_install/lib:\${LD_LIBRARY_PATH:-}"
_EOF_

source "${CUR}/project.sh"

# thorin
mkdir_cd "${CUR}/impala/thorin/build"
cmake .. ${CMAKE_MAKE} -DCMAKE_BUILD_TYPE:STRING=${BUILD_TYPE} ${LLVM_VARS} -DTHORIN_PROFILE:BOOL=${THORIN_PROFILE}
${MAKE}

# impala
mkdir_cd "${CUR}/impala/build"
cmake .. ${CMAKE_MAKE} -DCMAKE_BUILD_TYPE:STRING=${BUILD_TYPE}
${MAKE}

# runtime
cd "${CUR}"
clone_or_update AnyDSL runtime ${BRANCH_RUNTIME}
mkdir -p runtime/build
cd "${CUR}/runtime/build"
cmake .. ${CMAKE_MAKE} -DCMAKE_BUILD_TYPE:STRING=${BUILD_TYPE} -DRUNTIME_JIT:BOOL=${RUNTIME_JIT} -DImpala_DIR:PATH="${CUR}/impala/build/share/anydsl/cmake"
${MAKE}

# configure stincilla but don't build yet
cd "${CUR}"
clone_or_update AnyDSL stincilla ${BRANCH_STINCILLA}
mkdir_cd stincilla/build
cmake .. ${CMAKE_MAKE} -DCMAKE_BUILD_TYPE:STRING=${BUILD_TYPE} -DAnyDSL_runtime_DIR:PATH="${CUR}/runtime/build/share/anydsl/cmake" -DBACKEND:STRING="cpu"
#${MAKE}

# configure traversal but don't build yet
cd "${CUR}"
clone_or_update AnyDSL traversal ${BRANCH_TRAVERSAL}
mkdir_cd traversal/build
cmake .. ${CMAKE_MAKE} -DCMAKE_BUILD_TYPE:STRING=${BUILD_TYPE} -DAnyDSL_runtime_DIR:PATH="${CUR}/runtime/build/share/anydsl/cmake"
#${MAKE}

cd "${CUR}"

echo
red_echo "As a developer you probably want to use this git configuration in order to use SSH instead of HTTPS:"
red_echo "> git config --global url.ssh://git@github.com/.insteadOf https://github.com/"
red_echo "This switch automatically recurses through submodule"
red_echo "> git config --global submodule.recurse true"

echo
red_echo "Use the following command in order to have 'impala' and 'clang' in your path:"
red_echo "source project.sh"
