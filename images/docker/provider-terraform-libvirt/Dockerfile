# M4 step 5: `dmacvicar/libvirt`'s `xml { xslt = ... }` feature (used by
# the `cluster-talos-kvm` Composition's embedded Terraform module to set
# per-disk boot order and mark the Talos ISO read-only -- neither is
# expressible through the provider's native schema, confirmed by this
# repo's own M1-era investigation) shells out to the external `xsltproc`
# binary at apply time. The upstream provider-terraform image doesn't
# bundle it -- confirmed live (M4 step 5): `error applying XSLT
# stylesheet: exec: "xsltproc": executable file not found in $PATH`.
#
# A much narrower addition than the git-clone-credential problem that
# ruled out a custom image for `source: Remote` Workspaces (docs/memory/
# m4-design.md D4): this just adds one Alpine package on top of the
# unmodified upstream image, preserving its existing entrypoint/package
# metadata.
FROM xpkg.upbound.io/upbound/provider-terraform:v1.1.6
# Base image runs as non-root (uid 65532) by default; apk needs root to
# write its database. Restore the original non-root user afterward --
# Crossplane's own PodSecurityContext conventions expect it.
USER root
RUN apk add --no-cache libxslt
USER 65532
