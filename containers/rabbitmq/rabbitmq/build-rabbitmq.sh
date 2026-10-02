#!/bin/sh

# Source-build Erlang/OTP and Elixir, then use RabbitMQ's upstream Makefile
# targets and install layout from the CentOS Messaging SIG spec.
set -eux

rabbitmq_version="${RABBITMQ_VERSION:?RABBITMQ_VERSION must be set}"
otp_version="${OTP_VERSION:?OTP_VERSION must be set}"
elixir_version="${ELIXIR_VERSION:?ELIXIR_VERSION must be set}"
build_jobs="${BUILD_JOBS:-4}"

otp_src=/src/otp
elixir_src=/src/elixir
rabbitmq_src=/src/rabbitmq
rabbitmq_archive="/tmp/rabbitmq-server_${rabbitmq_version}.orig.tar.xz"
destdir=/rabbitmq-install

for src in "${otp_src}" "${elixir_src}" "${rabbitmq_src}"; do
    if [ ! -d "${src}" ]; then
        echo "Missing pinned source tree: ${src}" >&2
        exit 1
    fi
done

if [ ! -f "${rabbitmq_archive}" ]; then
    echo "Missing checksum-pinned RabbitMQ source archive: ${rabbitmq_archive}" >&2
    exit 1
fi

if [ "$(cat "${elixir_src}/VERSION")" != "${elixir_version}" ]; then
    echo "Elixir source version does not match ELIXIR_VERSION=${elixir_version}" >&2
    exit 1
fi

# Match the source layout Koji builds: the Git checkout used for source
# pinning does not contain all release dependencies, while this distribution
# archive bundles them.
rabbitmq_release_src="/src/rabbitmq-server-${rabbitmq_version}"
rm -rf "${rabbitmq_src}" "${rabbitmq_release_src}"
tar -xJf "${rabbitmq_archive}" -C /src
if [ ! -f "${rabbitmq_release_src}/Makefile" ] || \
    [ ! -f "${rabbitmq_release_src}/deps/thoas/src/thoas.erl" ] || \
    [ ! -f "${rabbitmq_release_src}/deps/rabbit_common/Makefile" ]; then
    echo "RabbitMQ source archive is missing the expected release tree or bundled dependencies" >&2
    exit 1
fi
mv "${rabbitmq_release_src}" "${rabbitmq_src}"

apply_patch_series() {
    source_dir="$1"
    shift
    cd "${source_dir}"
    for patch_file in "$@"; do
        patch -p1 --forward -i "${patch_file}"
    done
}

echo "Applying the CentOS Messaging SIG RabbitMQ patch series"
apply_patch_series "${rabbitmq_src}" /patches/rabbitmq/*.patch

echo "Applying the CentOS Messaging SIG Erlang/OTP patch series"
apply_patch_series "${otp_src}" /patches/otp/*.patch

echo "Applying the CentOS Messaging SIG Elixir patch series"
apply_patch_series "${elixir_src}" \
    /patches/elixir/elixir-0001-Fix-shebang.patch \
    /patches/elixir/increase-timeouts-for-tests.patch \
    /patches/elixir/elixir-0003-Limit-version-numbers-to-14-bytes.patch

case "${build_jobs}" in
    ''|*[!0-9]*|0)
        echo "BUILD_JOBS must be a positive integer" >&2
        exit 1
        ;;
esac

echo "Building Erlang/OTP ${otp_version} from source"

# Keep the OTP application set aligned with the RabbitMQ runtime needs while
# retaining the CentOS SIG's source-level fixes and hardening backports.
for app in \
    common_test debugger dialyzer diameter edoc et ftp jinterface megaco \
    observer odbc snmp ssh tftp wx; do
    touch "${otp_src}/lib/${app}/SKIP"
done

cd "${otp_src}"
./otp_build autoconf
otp_cflags="-O2 -g ${CFLAGS:-} -fno-strict-aliasing"
# RabbitMQ uses TCP for its transports; SCTP would add an lksctp build/runtime dependency.
CFLAGS="${otp_cflags}" CXXFLAGS="${otp_cflags}" ./configure \
    --prefix=/opt/erlang \
    --libdir=/opt/erlang/lib \
    --enable-shared-zlib \
    --enable-dynamic-ssl-lib \
    --enable-hybrid-heap \
    --enable-kernel-poll \
    --enable-jit \
    --disable-silent-rules \
    --with-microstate-accounting=extra \
    --without-javac \
    --without-odbc \
    --without-snmp \
    --without-ssh \
    --without-tftp \
    --without-ftp \
    --without-common_test \
    --without-debugger \
    --without-dialyzer \
    --without-et \
    --without-wx \
    --without-megaco \
    --without-observer \
    --without-reltool \
    --without-edoc \
    --without-jinterface \
    --disable-sctp \
    --without-diameter
make clean
make -j"${build_jobs}"
make install

export PATH="/opt/erlang/bin:/opt/erlang/lib/erlang/bin:${PATH}"

echo "Building Elixir ${elixir_version} from source"
cd "${elixir_src}"
make PREFIX=/opt/elixir install
export PATH="/opt/elixir/bin:${PATH}"

echo "Building RabbitMQ ${rabbitmq_version} from source"
cd "${rabbitmq_src}"
echo "Using the bundled erlang.mk defaults, as in the CentOS SIG build"

# If a source dependency is missing, record whether the release archive had
# its expected dependencies and which Rebar3 pins its bundled erlang.mk uses.
dump_rabbitmq_context() {
    hex_core_dir="${rabbitmq_src}/deps/hex_core"
    echo "RabbitMQ dependency source state after build failure"
    for dep in rabbit_common thoas; do
        if [ -d "${rabbitmq_src}/deps/${dep}" ]; then
            echo "Present: ${rabbitmq_src}/deps/${dep}"
        else
            echo "Missing: ${rabbitmq_src}/deps/${dep}"
        fi
    done
    if [ -d "${hex_core_dir}" ]; then
        git -C "${hex_core_dir}" rev-parse HEAD || true
        for config in rebar.config rebar.config.script; do
            if [ -f "${hex_core_dir}/${config}" ]; then
                echo "--- ${hex_core_dir}/${config}"
                cat "${hex_core_dir}/${config}"
            fi
        done
        echo "Hex Core plugin source files:"
        find "${hex_core_dir}" -maxdepth 4 -type f -path '*/plugins/*' -print || true
    else
        echo "No Hex Core checkout in the RabbitMQ release source tree"
    fi
    grep -nE '^(pkg_hex_core_commit|REBAR3_COMMIT)[[:space:]]*[:?+]?=' \
        "${rabbitmq_src}/erlang.mk" || true
}

if ! make PROJECT_VERSION="${rabbitmq_version}" \
    ESCRIPT_ZIP="zip -9 -X" V=1; then
    dump_rabbitmq_context
    exit 1
fi
if ! make install \
    PROJECT_VERSION="${rabbitmq_version}" \
    ESCRIPT_ZIP="zip -9 -X" \
    DESTDIR="${destdir}" \
    PREFIX=/usr \
    RMQ_ROOTDIR=/usr/lib/rabbitmq; then
    dump_rabbitmq_context
    exit 1
fi

# Recreate the wrappers and links installed by the SIG RPM. The container
# does not ship its systemd unit, tmpfiles rule, OCF agent, or logrotate file.
for app in rabbitmqctl rabbitmq-server rabbitmq-plugins rabbitmq-diagnostics; do
    install -p -D -m 0755 scripts/rabbitmq-script-wrapper "${destdir}/usr/sbin/${app}"
done

mkdir -p "${destdir}/usr/lib/rabbitmq/bin"
for app_path in "${destdir}/usr/lib/rabbitmq/lib/rabbitmq_server-${rabbitmq_version}"/sbin/*; do
    [ -e "${app_path}" ] || continue
    app="${app_path##*/}"
    ln -sfn "../lib/rabbitmq_server-${rabbitmq_version}/sbin/${app}" \
        "${destdir}/usr/lib/rabbitmq/bin/${app}"
done
ln -sfn "./lib/rabbitmq_server-${rabbitmq_version}/plugins" \
    "${destdir}/usr/lib/rabbitmq/plugins"

rm -rf "${elixir_src}" "${otp_src}" "${rabbitmq_src}"
