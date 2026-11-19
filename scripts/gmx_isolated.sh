#!/usr/bin/env bash
# Unset parent OpenMPI / PMIx rank variables so child gmx_mpi initializes cleanly
# when spawned as a subprocess from an MPI-parallelized Python (ASE NEB) driver.
unset OMPI_COMM_WORLD_SIZE OMPI_COMM_WORLD_RANK OMPI_COMM_WORLD_LOCAL_RANK
unset OMPI_COMM_WORLD_NODE_RANK OMPI_UNIVERSE_SIZE PMIX_RANK PMIX_NAMESPACE
exec gmx_mpi "$@"
