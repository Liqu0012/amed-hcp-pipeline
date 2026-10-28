FROM qunex/qunex_suite:1.5.1

LABEL org.opencontainers.image.title="Portable HCP Pipelines runtime" \
      org.opencontainers.image.description="Pinned QuNex/HCP runtime; mount data and FreeSurfer license externally" \
      org.opencontainers.image.version="1.5.1"

ENV LC_ALL=C LANG=C

# Workflow scripts are mounted at runtime so scheduler/site configuration stays
# outside the immutable scientific software image.
ENTRYPOINT ["/bin/bash"]
