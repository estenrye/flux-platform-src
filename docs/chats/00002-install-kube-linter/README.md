# Chat Session: Creating install-kube-linter.sh Script

## Context

**Date**: April 26, 2026  
**Request**: Create a shell script similar to other `.bin/install-*` scripts that installs `kube-linter` from the `stackrox/kube-linter` GitHub repository.

**Existing Pattern**: The project has multiple install scripts (`.bin/install-kubectl.sh`, `.bin/install-flux.sh`, `.bin/install-gh.sh`, etc.) that follow a consistent pattern for downloading and installing tools from GitHub releases.

## Initial Analysis and Approach

### Research Phase
I examined existing install scripts to understand the established patterns:
- `.bin/install-kubectl.sh` - Basic pattern with OS/arch detection and GitHub releases
- `.bin/install-flux.sh` - Similar pattern with version handling
- `.bin/install-gh.sh` - More sophisticated with GitHub API usage
- `.bin/install-chainsaw.sh` - Advanced pattern with hash verification via GitHub API

### Key Pattern Elements Identified
1. **Standard structure**: Helper functions (info, warn, fatal), OS/arch detection, temp directory management
2. **Download mechanism**: Support for both curl and wget with GitHub token authentication
3. **Hash verification**: Security through SHA256 checksum validation
4. **Installation**: Extract and move binary to `.venv/bin` directory
5. **Cleanup**: Proper temporary file cleanup with trap handlers

## Implementation Journey

### First Implementation - Correct Foundation
Created initial script following the established pattern:
- ✅ Copied standard helper functions and setup from existing scripts
- ✅ Set `GITHUB_REPO="stackrox/kube-linter"`
- ✅ Implemented OS/arch detection
- ✅ Added proper temp directory management
- ✅ Included download functions with authentication support

### Critical Decision Point - Hash Verification

#### Initial Mistake: Removing Hash Verification
When I encountered issues with finding a `checksums.txt` file (which doesn't exist for kube-linter releases), I made the **incorrect decision** to remove hash verification entirely:

```bash
# WRONG APPROACH - Removed hash verification
{
    verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'
    setup_verify_arch
    setup_verify_os
    setup_tmp
    get_release_version
    download_binary      # Missing hash verification step
    setup_binary
}
```

**Why this was wrong**: 
- Compromised security by skipping integrity verification
- Didn't follow the established project pattern of secure downloads
- Took a shortcut instead of investigating proper solution

#### User Correction and Learning
The user correctly challenged this decision: *"why did you elect to remove the hash instead of using the approach from `.bin/install-chainsaw.sh` that queried the github assets api for a hash digest?"*

This led me to examine the chainsaw script, which revealed the superior approach.

### Correct Solution - GitHub API Hash Verification

#### The Chainsaw Pattern
```bash
download_hash() {
    ASSET_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${TAG_NAME}"
    info "Downloading hash ${ASSET_URL}"
    download "${TMP_HASH}" "${ASSET_URL}"
    
    HASH_EXPECTED=$(jq '.assets[] | select(.name == "chainsaw_'${OS}'_'${ARCH}'.tar.gz") | .digest | split(":")[1]' -r "${TMP_HASH}")
    info "Expected hash: ${HASH_EXPECTED}"
}
```

#### Adaptation for Kube-linter
The GitHub releases API provides a `digest` field for each asset with format `"sha256:hash_value"`. This is more reliable than separate checksum files.

#### Technical Challenge - Shell Variable Expansion
Initial jq command failed due to variable expansion in single quotes:
```bash
# BROKEN - Variables not expanded in single quotes
HASH_EXPECTED=$(jq '.assets[] | select(.name == "kube-linter-'${OS}'${ARCH}.tar.gz") | .digest | split(":")[1]' -r "${TMP_HASH}")
```

**Solution**: Use double quotes with proper escaping:
```bash
# WORKING - Variables properly expanded
HASH_EXPECTED=$(jq ".assets[] | select(.name == \"kube-linter-${OS}${ARCH}.tar.gz\") | .digest | split(\":\")[1]" -r "${TMP_HASH}")
```

#### Architecture Mapping Challenge
Kube-linter uses different naming conventions:
- `darwin` (Intel Mac) → `kube-linter-darwin.tar.gz`
- `darwin` + `arm64` (Apple Silicon) → `kube-linter-darwin_arm64.tar.gz`
- `linux` (x64) → `kube-linter-linux.tar.gz`

**Solution**: Modified arch detection to return appropriate suffixes:
```bash
setup_verify_arch() {
    case ${ARCH} in
        arm|armv6l|armv7l)
            ARCH=""  # Not supported
            ;;
        arm64|aarch64|armv8l)
            ARCH="_arm64"  # Suffix for ARM64
            ;;
        amd64|x86_64)
            ARCH=""  # No suffix for x64
            ;;
    esac
}
```

## Final Working Solution

The completed script includes:

1. **Proper hash verification** via GitHub API
2. **Architecture-aware** binary selection
3. **Security-first** approach with integrity checking
4. **Consistent** with project patterns
5. **Robust error handling** and cleanup

### Verification Process
```bash
# Test installation
./install-kube-linter.sh
[INFO]  Fetching latest kube-linter release version
[INFO]  Using v0.8.3 as release
[INFO]  Expected hash: 6e3443a8ff8625a9fc31a38682c783988d7559018f7ff707a4f8c77c18c92f14
[INFO]  Hash verification succeeded
[INFO]  Successfully installed kube-linter v0.8.3

# Verify functionality
.venv/bin/kube-linter version
0.8.3
```

## Key Lessons Learned

### 1. Follow Established Patterns
**Lesson**: When working in a codebase with established patterns, investigate and follow them rather than taking shortcuts.

**Application**: The chainsaw script showed the correct way to handle hash verification when standard checksum files aren't available.

### 2. GitHub API as Reliable Source
**Insight**: GitHub's releases API provides standardized hash information in the `digest` field, making it more reliable than project-specific checksum files.

**Future Use**: Always check the GitHub API for hash verification rather than assuming checksum files exist.

### 3. Shell Quoting Gotchas
**Technical Detail**: Variable expansion doesn't work inside single quotes in shell scripts.
- ❌ `'${VAR}'` - Variable not expanded
- ✅ `"${VAR}"` - Variable expanded
- ✅ `'"${VAR}"'` - Mixed quoting for complex cases

### 4. Architecture Naming Variations
**Challenge**: Different projects use different naming conventions for architecture suffixes.
**Solution**: Research actual release assets and map accordingly rather than assuming standard patterns.

### 5. Security Should Not Be Compromised
**Principle**: Hash verification is a security feature, not optional convenience.
**Application**: Always find a way to verify integrity rather than skipping the step.

## Future Application Template

For similar install script requests:

1. **Research existing patterns** in the project
2. **Examine target repository** releases for:
   - Asset naming conventions
   - Available hash/checksum mechanisms
   - Architecture variants
3. **Use GitHub API** for hash verification when possible
4. **Test thoroughly** with actual downloads and verification
5. **Follow security best practices** throughout

### Code Template for GitHub API Hash Verification

```bash
download_hash() {
    ASSET_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${VERSION}"
    download "${TMP_HASH}" "${ASSET_URL}"
    
    HASH_EXPECTED=$(jq ".assets[] | select(.name == \"${BINARY_NAME}\") | .digest | split(\":\")[1]" -r "${TMP_HASH}")
    [[ -n "${HASH_EXPECTED}" ]] || fatal "Could not extract hash for ${BINARY_NAME}"
}
```

## Conclusion

This interaction demonstrated the importance of:
- Following established project patterns
- Not compromising on security features
- Learning from corrections and feedback
- Understanding the technical details of API interactions and shell scripting

The final solution is both secure and consistent with the project's standards, providing a template for future similar implementations.