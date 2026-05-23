"""Shared types and constants for the k3s update tool."""
import re
from collections import namedtuple

RefInfo = namedtuple("RefInfo", ["registry", "image", "tag", "prefix"])
ChartResult = namedtuple(
    "ChartResult",
    ["file", "status", "chart", "repo", "version", "current", "content"],
    defaults=["", "", "", "", ""],
)
ResolveResult = namedtuple("ResolveResult", ["resolved", "category", "detail"])

CAT_RESOLVED = "resolved"
CAT_FLAVORED = "flavored"
CAT_MAJOR_AVAIL = "major_available"
CAT_SEMVER_FALLBACK = "semver_fallback"
CAT_ERROR = "error"
CAT_NO_CHANGE = "no_change"
CAT_DIGEST_PIN = "digest_pin"

FLAVOR_RE = re.compile(
    r"^(alpine|slim|bookworm|bullseye|openssl|uclibc)$"
    r"|-(alpine|slim|bookworm|bullseye|openssl|uclibc)$"
)
SEMVER_TAG_RE = re.compile(r"^(\d+)(?:\.(\d+)(?:\.(\d+))?)?(.*)$")
SUFFIX_DIGIT_RE = re.compile(r"^[-_\.]\d")
PRERELEASE_RE = re.compile(r"[-_](beta|rc|alpha|dev)\b")
PURE_SEMVER_RE = re.compile(r"^v?\d+(\.\d+)+$")
PURE_NUMERIC_LINE_RE = re.compile(r"^v?\d+(?:\.\d+)*$")

DIRECT_IMAGE_RE = re.compile(r"^\s*image:[^\S\n]*(\S+)", re.MULTILINE)
SEMVER_TRIPLE_RE = re.compile(r"^\d+\.\d+\.\d+$")

_SKIP_KEYS = frozenset({
    "env", "envFrom", "resources", "securityContext", "extraArgs",
    "extraEnv", "command", "args", "volumeMounts", "volumes", "ports",
    "livenessProbe", "readinessProbe", "startupProbe", "lifecycle",
    "podSecurityContext", "containerSecurityContext", "affinity",
    "tolerations", "nodeSelector", "serviceAccountName",
    "topologySpreadConstraints",
})
