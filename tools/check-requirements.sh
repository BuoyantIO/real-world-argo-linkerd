# Make sure that we have what we need in our $PATH.

set -e

check () {
    cmd="$1"
    url="$2"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing: $cmd (see $url)" >&2
        exit 1
    fi
}

check_argocd_version () {
    # This is really kinda ugly, huh?
    want=$(curl --silent "https://api.github.com/repos/argoproj/argo-cd/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    have=$(argocd version --client --short | sed -e 's!^[^v][^v]*\(v[^+][^+]*\)+.*$!\1!')

    if [ "$have" != "$want" ]; then
        echo "Have argocd version $have, but want $want" >&2
        echo "See https://argo-cd.readthedocs.io/en/stable/getting_started/"
        exit 1
    fi
}

check linkerd "https://linkerd.io/2/getting-started/"
check argocd "https://argo-cd.readthedocs.io/en/stable/getting_started/"
check kubectl "https://kubernetes.io/docs/tasks/tools/"
check kubectl-argo-rollouts "https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation"
check kubeseal 'https://github.com/bitnami-labs/sealed-secrets?tab=readme-ov-file#kubeseal'
check step "https://smallstep.com/docs/step-cli/installation"
check bat "https://github.com/sharkdp/bat"
check helm "https://helm.sh/docs/intro/quickstart/"
check yq "https://github.com/mikefarah/yq?tab=readme-ov-file#install"
check_argocd_version
