#!/bin/bash
# commands run to provision host after startup

# see also:
# http://wiki.eng.zimbra.com/index.php/ZimbraMaven#Jars_which_are_not_available_in_Maven
# - Zimbra patched jars files are in ZimbraCommon/jars-bootstrap in perforce
# - ant reset-all calls the 'maven-seed-local-repo' target
# - if/when modifying your Maven local repository (~/.m2/repository)
#   also check ZimbraServer/mvn.seed.properties (used by ant)
#   see also the mvn-local-jars shell script to populate the local repository

prog=${0##*/}
MYSQLPASS="zimbra"
P4CLIENTURL="http://cdist2.perforce.com/perforce/r15.1/bin.linux26x86_64/p4"
ZIMBRA_HOME="/opt/zimbra"

# ID="SomeThing" - remove up to equals sign and strip double quotes
dist=$( \
  grep ^ID= /etc/os-release 2>/dev/null \
  || cut -d: -f 3 /etc/system-release-cpe 2>/dev/null \
  || grep ^DISTRIB_ID= /etc/lsb-release 2>/dev/null \
  )
dist=${dist,,}
dist=${dist#*=}
dist=${dist#*\"}
dist=${dist%*\"}

case "$dist" in
    centos|ubuntu)
        ;;
    *)
        echo "$prog does not support OS '$dist' yet"
        exit 1
        ;;
esac

function say () { builtin echo $(date --rfc-3339=s): "$@" 1>&2; }

function usage ()
{
    for info in "$@"; do
        say "$info"
    done
    cat <<EOF
Usage: $prog <[-b][-d][-r]>
  environment type (choose all desired zimbra related environments):
    -b  == build       ThirdParty FOSS (gcc,headers,libs,etc.)
    -d  == development Full ZCS builds (consul,mariadb,redis,memcached...)
    -r  == runtime     Runtime for ZCS (curl,gzip,libaio,netcat,sysstat,tar,wget)

  Notes:
   - dev: ant, maven, java
   - build|dev installs: make
   - development uses non-standard ZCS components (instead of building
     the components from ThirdParty)

EOF
}

[[ "$#" -eq 0 ]] && usage "an argument is required" && exit 1
while getopts "bdrh" opt; do
    case "$opt" in
        b) buildenv=1; say "selecting environment: build" ;;
        d) devenv=1;   say "selecting environment: development" ;;
        r) runenv=1;   say "selecting environment: runtime" ;;
        h) usage && exit 0 ;;
        \?) errors=1 ;;
    esac
done
shift $((OPTIND-1))
[[ -n "$errors" ]] && usage "invalid arguments" && exit 3
[[ "$#" -ne 0 ]] && usage "invalid argument: $1" && exit 3

# order can be important:
# - (any/some) java required by ant or maven
function main ()
{
    env_all_pre
    [[ -n "$buildenv" || -n "$devenv" ]] && env_build_dev
    [[ -n "$runenv" ]] && env_run
    [[ -n "$devenv" ]] && env_dev
    [[ -n "$buildenv" ]] && env_build
    env_all_post
    exit 0
}

# build+dev+run
function env_all_pre ()
{
    if [[ -n "$ZIMBRA_HOME" ]]; then
        _install_dirs "$ZIMBRA_HOME"
    fi
    env_all_pre_$dist
}
function env_all_pre_centos () {
    say "Running yum makecache fast..."
    yum makecache fast
}
function env_all_pre_ubuntu () {
    export DEBIAN_FRONTEND=noninteractive
    say "Running apt-get update ..."
    apt-get update -y -qq
    apt-get install -y software-properties-common
}

function env_all_post () {
    _install git

    [[ "$dist" = "ubuntu" ]] && env_all_post_$dist
}
function env_all_post_ubuntu () {
    say "Running apt-get dist-upgrade..."
    apt-get update -y -qq && apt-get dist-upgrade -y -qq
}

# dev - ideally java is already installed before ant and maven
function env_dev ()
{
    env_run
    _install_ant_maven # ant/maven for dev env
    _install_java 7 # JP dev requirement
    _install_zdevtools # reviewboard
    _install memcached
    #OFF _install redis-server # AlwaysOn / main
    _install_mariadb_server
    #OFF _install_consul 0.5.2 # AlwaysOn / main
    _link_zimbra_common

    _install zimbra-openldap-server zimbra-openldap-client zimbra-rsync \
             zimbra-openssl zimbra-openjdk zimbra-openjdk-cacerts \
             zimbra-tcmalloc-lib

    _install_dirs \
        "$ZIMBRA_HOME/common/var" \
        "$ZIMBRA_HOME/common/etc/openldap" \
        "$ZIMBRA_HOME/common/etc/openldap/schema"

    if [[ "$dist" = "ubuntu" ]]; then
        install -d /etc/profile.d
        install -m 755 /vagrant/scripts/zimbra-profile.sh /etc/profile.d

        install -m 755 /vagrant/scripts/dev-init.sh /etc/init.d/zimbra
        update-rc.d zimbra defaults
    fi
}

# run
function env_run ()
{
    _install curl gzip sysstat tar wget
    env_run_$dist
}
function env_run_centos () { _install libaio nc; }
function env_run_ubuntu () { _install libaio1 netcat; }

# build - compilers, dev headers/libs, packaging, ...
# - note: jdk 1.7 is needed to build openjdk 1.8 but for now we will
#   handle that as part of that package's build process
function env_build () { _install_buildtools; }
function env_build_dev ()
{
    _install make
    #OFF _install_java 8
    env_build_dev_$dist
}
function env_build_dev_centos () {
    say "Adding Zimbra repository ..."
    rpm --import https://files.zimbra.com/downloads/security/public.key
    cat > /etc/yum.repos.d/zimbra.repo <<EOF
[zimbra]
name=Zimbra RPM Repository
baseurl=https://repo.zimbra.com/rpm/87/rhel$(rpm -qa --queryformat '%{VERSION}\n' '(redhat|sl|slf|centos|oraclelinux)-release(|-server|-workstation|-client|-computenode)')
gpgcheck=1
enabled=1
EOF
    yum -q --disablerepo=* --enablerepo=zimbra clean metadata
    yum -q --disablerepo=* --enablerepo=zimbra --noplugins check-update
}
function env_build_dev_ubuntu () {
    say "Adding Zimbra repository ..."
    _install apt-transport-https
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 9BE6ED79
    cat > /etc/apt/sources.list.d/zimbra.list <<EOF
deb [arch=amd64] https://repo.zimbra.com/apt/87 $(lsb_release -cs) zimbra
deb-src [arch=amd64] https://repo.zimbra.com/apt/87 $(lsb_release -cs) zimbra
EOF
    apt-get update -y -qq
}

###
function _install () { say "Installing packages: $@"; _install_$dist "$@"; }
function _install_centos () { yum install -y -q "$@"; }
function _install_ubuntu () { apt-get install -y -qq "$@"; }

function _add_repo ()
{
    for rep in "$@"; do
        say "Adding repository '$rep' ..."
        add-apt-repository -y "$rep"
    done
    say "Running apt-get update ..."
    apt-get update -y -qq
}

function _install_p4client ()
{
    # p4 client
    cd /usr/local/bin && wget -nv "$P4CLIENTURL" && chmod 755 p4
}

function _install_zdevtools ()
{
    _install_p4client
    _install python-pip && pip install -U RBTools # reviewboard

    [[ "$dist" = "ubuntu" ]] && _install libnss-mdns
    [[ "$dist" = "centos" ]] && _install nss-mdns
}

function _install_dirs ()
{
    say "Creating directories: $*"
    install -m a+rx,ug+w,+t -g vagrant -d "$@"
}

# build environment
# - dependency notes:
#   - apache/nginx: [lib]pcre-dev[el]
#   - curl: {perl,}libwww-perl, [lib]z,
#   - heimdal: zlib [lib]ncurses
#   - mariadb: [lib]aio, [lib]ncurses
#   - tcmalloc: g++
#   - perl: [lib]perl-dev[el]
#   - rrdtool: perl-ExtUtils-MakeMaker
#   - unbound: [lib]expat-dev[el]
#   - freetype: [lib]b[ip]z2-dev[el] (for rrdtool)
#   - rsync/compress::bz...: [lib]popt-dev[el]
function _install_buildtools ()
{
    pkgs=(
        patch
        bzip2 perl unzip # perl
        autoconf automake libtool # curl
        bison cmake # mariadb([lib]{aio,curses})
        gcc tar
        m4 # heimdal
        mercurial zip # openjdk
    )
    _install "${pkgs[@]}"
    _install_buildtools_$dist
}

function _install_buildtools_centos ()
{
    pkgs=(
        rpm-build
        gcc-c++ pkgconfig libidn-devel
        perl-libwww-perl zlib-devel libaio-devel ncurses-devel
        expat-devel pcre-devel perl-devel perl-ExtUtils-MakeMaker
        popt-devel bzip2-devel perl-Test-Simple perl-core
        perl-Socket6 perl-Test-Inter perl-Test-Warn perl-Test-Deep
    )
    _install "${pkgs[@]}"
}

function _install_buildtools_ubuntu ()
{
    pkgs=(
        debhelper
        g++ pkg-config libidn11-dev
        libwww-perl libz-dev libaio-dev libncurses-dev
        libexpat-dev libpcre3-dev libperl-dev
        libpopt-dev libbz2-dev libtest-simple-perl
        libsocket6-perl libtest-inter-perl libtest-warn-perl
        libtest-deep-perl
    )
    _install "${pkgs[@]}"
    # TBD: flex libreadline-dev cloog-ppl
}

# for java development
function _install_ant_maven () { _install_ant_maven_$dist; }
function _install_ant_maven_centos ()
{
    _install ant maven;
}
function _install_ant_maven_ubuntu ()
{
    _add_repo ppa:andrei-pozolotin/maven3
    _install ant maven3
}

# known versions: 7 8
function _install_java () { _install_java_$dist "$@"; }
function _install_java_centos ()
{
    for v in "$@"; do
        _install java-1.${v}.0-openjdk
    done
}
function _install_java_ubuntu () { _install_java_ubuntu_openjdk "$@"; }
function _install_java_ubuntu_openjdk ()
{
    _add_repo ppa:openjdk-r/ppa
    for v in "$@"; do
        _install openjdk-${v}-jdk
        update-java-alternatives -s java-1.${v}.0-openjdk-amd64
    done
}

function _link_zimbra_common ()
{
    ddir="${ZIMBRA_HOME}/common/sbin"
    if [[ -d "$ddir" ]]; then
        say "Directory '$ddir' already exists!"
    else
      ( #  do the work in a subshell since we're CD'ing
        mkdir -p "$ddir"
        cd "$ddir" || exit
        for bin in /usr/local/bin/consul $(type -p memcached) $(type -p redis-server)
        do
            if [[ -x "$bin" ]]; then
                say "Make symlink to '$bin' in '$ddir'"
                ln -s "$bin" "."
            fi
        done
      )
    fi
}

# consul
# - download via http://www.consul.io/downloads.html
#   /usr/local/bin/consul agent -server -bootstrap-expect 1 -data-dir /var/tmp/consul
function _install_consul ()
{
    _install zip
    zip="$1"_linux_amd64.zip
    url="https://dl.bintray.com/mitchellh/consul/""$zip"
    loc="/usr/local/bin"
    bin="$loc""/consul"
    if [[ -x "$bin" ]]; then
        say "consul: '$bin' already installed"
        return
    else
      ( #  do the work in a subshell since we're CD'ing
        cd "$loc" && wget -nv "$url" && unzip "$zip" && rm "$zip" && chmod 755 "$bin"
        [[ ! -x "$bin" ]] && say "consul: '$bin' install failed!"
      )
    fi
}

function _install_mariadb_server () { _install_mariadb_server_$dist; }
function _install_mariadb_server_centos () {
    _install mariadb-server
    say "TODO: configure mariadb: set port=7306; sock=${ZIMBRA_HOME}/mysql/data/mysqld.sock"
}
function _install_mariadb_server_ubuntu () {
    debconf-set-selections <<< "mysql-server mysql-server/root_password password $MYSQLPASS"
    debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $MYSQLPASS"
    _install mariadb-server
    _mariadb_setup
}

function _mariadb_setup ()
{
    service mysql stop
    myfile="/etc/mysql/my.cnf"
    (
        pfrom=3306; pto=7306;
        say "Replacing '$pfrom' with '$pto' in '$myfile'"
        perl -pi -e "s,$pfrom,$pto,g" "$myfile"
    )
    (
        fdir="/var/lib/mysql"; ddir="${ZIMBRA_HOME}/mysql/data"
        if [[ -d "$ddir" ]]; then
            say "Directory '$ddir' already exists!"
        else
            say "Copying data from '$fdir' to '$ddir'"
            mkdir -p "$ddir" && cp -pr "$fdir"/* "$ddir" && chown mysql:mysql "$ddir"
            [[ -e "$ddir"/mysqld.sock ]] && rm "$ddir"/mysqld.sock
            ln -s "/var/run/mysqld/mysqld.sock" "$ddir"/mysqld.sock
            say "Replacing '$fdir' with '$ddir' in '$myfile'"
            perl -pi -e "s,${fdir},${ddir},g if /^datadir/" "$myfile"
        fi
    )
    service mysql start
}

# call main
main
