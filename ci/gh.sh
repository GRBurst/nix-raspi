# shellcheck shell=bash
#
# ci/gh.sh — GitHub Actions feedback for the rpi-ci scripts: annotations,
# log groups and the step summary. Sourced; defines functions only.
#
#   gh_notice MSG | gh_warning MSG    annotation (stderr)
#   gh_error MSG [FILE [LINE]]        error annotation, optionally on FILE:LINE
#   gh_group TITLE / gh_endgroup      a collapsible log group (stderr)
#   gh_summary < MARKDOWN             append to $GITHUB_STEP_SUMMARY
#   gh_on                             0 iff running under GitHub Actions
#
# All of it only when GITHUB_ACTIONS=true (the runner sets it): elsewhere
# (a local run, the unit tests) annotations are plain `rpi-ci: LEVEL: MSG`
# lines on stderr, groups and the summary do nothing. Annotations go to
# stderr because the scripts' stdout is $GITHUB_OUTPUT (the runner reads
# workflow commands from both). Messages are escaped as the runner expects
# (% CR LF; in properties also : and ,), so one annotation is one line.

gh_on() { [[ "${GITHUB_ACTIONS:-}" == true ]]; }

# gh_esc S: S escaped as annotation data; gh_esc_prop S: as a property value
gh_esc() {
    local s="${1//%/%25}"
    s="${s//$'\r'/%0D}"
    printf '%s' "${s//$'\n'/%0A}"
}
gh_esc_prop() {
    local s
    s="$(gh_esc "$1")"
    s="${s//:/%3A}"
    printf '%s' "${s//,/%2C}"
}

# gh_annotate LEVEL MSG [FILE [LINE]]
gh_annotate() {
    local level="$1" msg="$2" file="${3:-}" line="${4:-}" props=""
    if gh_on; then
        [[ -z "$file" ]] || props=" file=$(gh_esc_prop "$file")${line:+,line=$(gh_esc_prop "$line")}"
        printf '::%s%s::%s\n' "$level" "$props" "$(gh_esc "$msg")" >&2
    else
        printf 'rpi-ci: %s: %s%s\n' "$level" "${file:+$file${line:+:$line}: }" "$msg" >&2
    fi
}

gh_notice() { gh_annotate notice "$1"; }
gh_warning() { gh_annotate warning "$1"; }
gh_error() { gh_annotate error "$@"; }

gh_group() { if gh_on; then printf '::group::%s\n' "$(gh_esc "$1")" >&2; fi; }
gh_endgroup() { if gh_on; then echo '::endgroup::' >&2; fi; }

gh_summary() {
    if gh_on && [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        cat >>"$GITHUB_STEP_SUMMARY"
    else
        cat >/dev/null
    fi
}
