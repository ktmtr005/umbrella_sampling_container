# syntax=docker/dockerfile:1
# =============================================================================
# HPC QM/MM (ASE + GROMACS + CP2K/tblite + PLUMED) Container on Rocky Linux 9
# =============================================================================
FROM rockylinux:9

ARG OPENMPI_VERSION=4.1.6
ARG SCALAPACK_VERSION=2.2.0
ARG TBLITE_VERSION=0.4.0
ARG DBCSR_VERSION=2.7.0
ARG CP2K_VERSION=2024.3
ARG PLUMED_VERSION=2.9.2
ARG GROMACS_VERSION=2024.3

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# -----------------------------------------------------------------------------
# Step 1: System Dependencies, Python 3.11 & Unified OpenMPI Stack
# -----------------------------------------------------------------------------
RUN dnf -y install dnf-plugins-core epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf -y update && \
    dnf -y install --allowerasing \
        gcc \
        gcc-c++ \
        gcc-gfortran \
        make \
        cmake \
        ninja-build \
        meson \
        pkgconf-pkg-config \
        git \
        wget \
        curl \
        tar \
        bzip2 \
        xz \
        which \
        findutils \
        perl \
        patch \
        diffutils \
        file \
        flex \
        bison \
        openblas-devel \
        lapack-devel \
        fftw-devel \
        gsl-devel \
        zlib-devel \
        hwloc-devel \
        libevent-devel \
        numactl-devel \
        python3.11 \
        python3.11-devel \
        python3.11-pip && \
    ln -sf /usr/bin/python3.11 /usr/local/bin/python3 && \
    ln -sf /usr/bin/pip3.11 /usr/local/bin/pip3 && \
    dnf clean all && \
    rm -rf /var/cache/dnf

RUN mkdir -p /tmp/build && cd /tmp/build && \
    curl -fsSL "https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-${OPENMPI_VERSION}.tar.bz2" -o openmpi.tar.bz2 && \
    tar -xjf openmpi.tar.bz2 && \
    cd "openmpi-${OPENMPI_VERSION}" && \
    ./configure \
        --prefix=/opt/openmpi \
        --with-pmix=internal \
        --with-hwloc=external \
        --with-libevent=external \
        --enable-mpi-cxx && \
    make -j"$(nproc)" && \
    make install && \
    rm -rf /tmp/build

ENV PATH="/opt/openmpi/bin:/usr/local/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/openmpi/lib" \
    CC=mpicc \
    CXX=mpicxx \
    FC=mpifort

# -----------------------------------------------------------------------------
# Step 2: Build ScaLAPACK & tblite (GFN2-xTB Engine) against Unified OpenMPI
# -----------------------------------------------------------------------------
RUN mkdir -p /tmp/build && cd /tmp/build && \
    curl -fsSL "https://github.com/Reference-ScaLAPACK/scalapack/archive/refs/tags/v${SCALAPACK_VERSION}.tar.gz" -o scalapack.tar.gz && \
    tar -xzf scalapack.tar.gz && \
    cd "scalapack-${SCALAPACK_VERSION}" && \
    cmake -B _build \
        -DCMAKE_INSTALL_PREFIX=/opt/scalapack \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_C_COMPILER=mpicc \
        -DCMAKE_Fortran_COMPILER=mpifort \
        -DCMAKE_Fortran_FLAGS="-fallow-argument-mismatch" \
        -DBLAS_LIBRARIES=/usr/lib64/libopenblas.so \
        -DLAPACK_LIBRARIES=/usr/lib64/liblapack.so && \
    cmake --build _build -j"$(nproc)" && \
    cmake --install _build && \
    rm -rf /tmp/build

RUN mkdir -p /tmp/build && cd /tmp/build && \
    git clone --depth 1 --branch "v${TBLITE_VERSION}" https://github.com/tblite/tblite.git && \
    cd tblite && \
    python3 -c 'import pathlib, re; p = pathlib.Path("config/cmake/tblite-utils.cmake"); txt = p.read_text() if p.exists() else ""; p.write_text(re.sub(r"^([ \t]*)(add_library\(([^ \)]+)\s+INTERFACE\s+IMPORTED\)\n[ \t]*target_link_libraries\([^\n]+\))", r"\1if(NOT TARGET \3)\n\1  \2\n\1endif()", txt, flags=re.M)) if (p.exists() and "if(NOT TARGET" not in txt) else None' && \
    cmake -B _build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/opt/tblite \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DWITH_OpenMP=ON && \
    cmake --build _build -j"$(nproc)" && \
    cmake --install _build && \
    rm -rf /tmp/build

ENV LD_LIBRARY_PATH="/opt/tblite/lib:/opt/scalapack/lib:${LD_LIBRARY_PATH}" \
    PKG_CONFIG_PATH="/opt/tblite/lib/pkgconfig" \
    CMAKE_PREFIX_PATH="/opt/tblite:/opt/scalapack"

# -----------------------------------------------------------------------------
# Step 3: Build DBCSR & CP2K (libcp2k.so + cp2k.psmp with tblite)
# -----------------------------------------------------------------------------
RUN mkdir -p /tmp/build && cd /tmp/build && \
    git clone --depth 1 --branch "v${DBCSR_VERSION}" --recursive https://github.com/cp2k/dbcsr.git && \
    cd dbcsr && \
    cmake -B _build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/opt/dbcsr \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DUSE_MPI=ON \
        -DUSE_OPENMP=ON \
        -DWITH_EXAMPLES=OFF \
        -DWITH_C_API=OFF && \
    cmake --build _build -j"$(nproc)" && \
    cmake --install _build && \
    rm -rf /tmp/build

RUN mkdir -p /tmp/build && cd /tmp/build && \
    git clone --depth 1 --branch "v${CP2K_VERSION}" https://github.com/cp2k/cp2k.git && \
    cd cp2k && \
    cmake -B _build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/opt/cp2k \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DCP2K_USE_MPI=ON \
        -DCP2K_USE_OPENMP=ON \
        -DCP2K_USE_TBLITE=ON \
        -DCP2K_BLAS_VENDOR=OpenBLAS \
        -DCP2K_SCALAPACK_VENDOR=GENERIC \
        -DCP2K_USE_LIBXC=OFF \
        -DCP2K_USE_LIBINT2=OFF \
        -Ddbcsr_DIR=/opt/dbcsr/lib/cmake/dbcsr \
        -DCMAKE_PREFIX_PATH="/opt/tblite;/opt/scalapack;/opt/dbcsr" && \
    cmake --build _build -j"$(nproc)" && \
    cmake --install _build && \
    test -f /opt/cp2k/lib/libcp2k.so && \
    find /opt/cp2k/include -name "libcp2k.h" | grep -q . && \
    rm -rf /tmp/build

ENV PATH="/opt/cp2k/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/cp2k/lib:/opt/dbcsr/lib:${LD_LIBRARY_PATH}" \
    PKG_CONFIG_PATH="/opt/cp2k/lib/pkgconfig:/opt/dbcsr/lib/pkgconfig:${PKG_CONFIG_PATH}" \
    CMAKE_PREFIX_PATH="/opt/cp2k:/opt/dbcsr:${CMAKE_PREFIX_PATH}" \
    CP2K_DATA_DIR="/opt/cp2k/share/cp2k/data"

# -----------------------------------------------------------------------------
# Step 4: Build PLUMED with OpenMPI
# -----------------------------------------------------------------------------
RUN mkdir -p /tmp/build && cd /tmp/build && \
    curl -fsSL "https://github.com/plumed/plumed2/releases/download/v${PLUMED_VERSION}/plumed-${PLUMED_VERSION}.tgz" -o plumed.tgz && \
    tar -xzf plumed.tgz && \
    cd "plumed-${PLUMED_VERSION}" && \
    ./configure \
        --prefix=/opt/plumed \
        --enable-mpi \
        --enable-modules=all \
        CC=mpicc \
        CXX=mpicxx && \
    make -j"$(nproc)" && \
    make install && \
    rm -rf /tmp/build

ENV PATH="/opt/plumed/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/plumed/lib:${LD_LIBRARY_PATH}" \
    PLUMED_KERNEL="/opt/plumed/lib/libplumedKernel.so"

# -----------------------------------------------------------------------------
# Step 5: Patch & Build GROMACS (PLUMED + libcp2k + OpenMPI)
# -----------------------------------------------------------------------------
RUN mkdir -p /tmp/build && cd /tmp/build && \
    curl -fsSL "https://ftp.gromacs.org/gromacs/gromacs-${GROMACS_VERSION}.tar.gz" -o gromacs.tar.gz && \
    tar -xzf gromacs.tar.gz && \
    cd "gromacs-${GROMACS_VERSION}" && \
    ENGINE="gromacs-${GROMACS_VERSION}" && \
    if [ ! -e "/opt/plumed/lib/plumed/patches/${ENGINE}.diff" ]; then \
        DIFF_FILE="$(printf '%s\n' /opt/plumed/lib/plumed/patches/gromacs-${GROMACS_VERSION%.*}*.diff | sort -V | tail -n 1)" && \
        test -e "${DIFF_FILE}" && \
        ENGINE="$(basename "${DIFF_FILE}" .diff)"; \
    fi && \
    /opt/plumed/bin/plumed patch -p -e "${ENGINE}" && \
    set -- && \
    if ! pkg-config --exists libcp2k; then \
        set -- "-DCP2K_LINKER_FLAGS=-L/opt/cp2k/lib -lcp2k"; \
    fi && \
    cmake -B _build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/opt/gromacs \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=mpicc \
        -DCMAKE_CXX_COMPILER=mpicxx \
        -DGMX_MPI=ON \
        -DGMX_THREAD_MPI=OFF \
        -DGMX_OPENMP=ON \
        -DGMX_GPU=OFF \
        -DGMX_CP2K=ON \
        -DCP2K_DIR=/opt/cp2k \
        -Dcp2k_DIR=/opt/cp2k/lib/cmake/cp2k \
        "$@" \
        -DGMX_FFT_LIBRARY=fftw3 \
        -DGMX_BLAS_USER=/usr/lib64/libopenblas.so \
        -DGMX_LAPACK_USER=/usr/lib64/liblapack.so && \
    cmake --build _build -j"$(nproc)" && \
    cmake --install _build && \
    rm -rf /tmp/build

ENV PATH="/opt/gromacs/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/gromacs/lib:${LD_LIBRARY_PATH}" \
    GMXBIN="/opt/gromacs/bin" \
    GMXLDLIB="/opt/gromacs/lib" \
    GMXMAN="/opt/gromacs/share/man" \
    GMXDATA="/opt/gromacs/share/gromacs" \
    GMXLIB="/opt/gromacs/share/gromacs/top"

# -----------------------------------------------------------------------------
# Step 6: Python Environment (mpi4py built against container mpicc + ASE)
# -----------------------------------------------------------------------------
RUN MPICC="$(which mpicc)" python3 -m pip install --no-cache-dir --no-binary=mpi4py mpi4py && \
    python3 -m pip install --no-cache-dir numpy scipy ase

# -----------------------------------------------------------------------------
# Step 7: Helper Utilities & Verification Suite
# -----------------------------------------------------------------------------
COPY scripts/gmx_isolated.sh /opt/bin/gmx_isolated.sh
COPY scripts/verify_container.sh /opt/bin/verify_container.sh
COPY templates/cp2k_gfn2_qmmm.inp /opt/templates/cp2k_gfn2_qmmm.inp

RUN chmod +x /opt/bin/gmx_isolated.sh /opt/bin/verify_container.sh

ENV PATH="/opt/bin:${PATH}"

WORKDIR /workspace
CMD ["/bin/bash"]
