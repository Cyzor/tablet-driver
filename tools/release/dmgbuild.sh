# Sourced by the release scripts. Sets DMGBUILD to a dmgbuild executable,
# installing it into a gitignored venv on first use (pip can't install into
# Homebrew's or the runner's system Python).
if command -v dmgbuild >/dev/null 2>&1; then
    DMGBUILD=dmgbuild
else
    DMGBUILD_VENV="build/dmgbuild-venv"
    if [ ! -x "$DMGBUILD_VENV/bin/dmgbuild" ]; then
        echo "==> Installing dmgbuild into $DMGBUILD_VENV"
        python3 -m venv "$DMGBUILD_VENV"
        "$DMGBUILD_VENV/bin/pip" install --quiet dmgbuild
    fi
    DMGBUILD="$DMGBUILD_VENV/bin/dmgbuild"
fi
