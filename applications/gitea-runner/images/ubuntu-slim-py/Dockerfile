# Job image for the ubuntu-slim-py runner label: ubuntu-slim plus python3 and make.
# The base runs as root (empty USER), so no USER is set here. Rebuild and push:
# docs/runbooks/gitea.md.
FROM harbor.rye.ninja/gitea/runner-images@sha256:b60d2ff3f33a436926c1fc6d40be69edde2c7fe17355f52d4d252c4fc8587704
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make \
 && rm -rf /var/lib/apt/lists/*
