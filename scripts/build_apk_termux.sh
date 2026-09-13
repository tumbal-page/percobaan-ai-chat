#!/data/data/com.termux/files/usr/bin/bash
# Build the Android APK on Termux, without Gradle and without touching the
# system default `java`/`javac` (which may point at a different JDK).
#
# Toolchain used (all installed via `pkg install aapt2 d8 apksigner`):
#   aapt2 -> javac (JDK 17, explicit path) -> d8 -> [add dex via python zipfile]
#   -> [pack assets via pack_apk_assets.py] -> apksigner sign
#
# zipalign is deliberately SKIPPED: it is a memory-mmap optimization, not a
# build requirement. The APK installs and runs fine without it. This app has
# extractNativeLibs=false and no native libs, so the benefit would be
# negligible anyway.
#
# Prerequisites (one-time):
#   pkg install -y aapt2 d8 apksigner
#   ~/android-sdk/platforms/android-34/android.jar  (fetched via sdkmanager)
#
# Usage: run from the repo root: bash scripts/build_apk_termux.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JDK17="/data/data/com.termux/files/usr/lib/jvm/java-17-openjdk"
ANDROID_JAR="$HOME/android-sdk/platforms/android-34/android.jar"

# --- sanity checks: fail loud and early with a clear message -----------------
for p in "$JDK17/bin/javac" "$ANDROID_JAR"; do
  if [ ! -e "$p" ]; then
    echo "MISSING: $p" >&2
    exit 1
  fi
done
for cmd in aapt2 d8 apksigner python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "MISSING command: $cmd (pkg install it)" >&2; exit 1; }
done

AND="$ROOT/android"
WEB="$ROOT/web"
WORK="$ROOT/output/apk-work"
OUT="$ROOT/output/android"

echo "== version from config/version.json =="
VER=$(python3 -c "import json; print(json.load(open('$ROOT/config/version.json'))['version'])")
VC=$(python3 -c "import json; print(json.load(open('$ROOT/config/version.json'))['code'])")
echo "Building RyzaChat-$VER.apk (versionCode $VC)"

echo "== privacy gate on the tree that is about to be packed =="
python3 "$ROOT/scripts/privacy_check.py" "$WEB" "$AND/app/src/main"

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"

echo "== compile resources (aapt2) =="
aapt2 compile --dir "$AND/app/src/main/res" -o "$WORK/res.zip"

echo "== link base apk (manifest + resources) =="
aapt2 link \
  -o "$WORK/base.apk" \
  --manifest "$AND/app/src/main/AndroidManifest.xml" \
  -I "$ANDROID_JAR" \
  "$WORK/res.zip" \
  --auto-add-overlay \
  --min-sdk-version 24 --target-sdk-version 34 \
  --version-code "$VC" --version-name "$VER"

echo "== javac (JDK 17 explicit, not the system default) =="
CLS="$WORK/classes"
mkdir -p "$CLS"
find "$AND/app/src/main/java" -name "*.java" > "$WORK/srcs.txt"
"$JDK17/bin/javac" -nowarn -encoding UTF-8 --release 11 \
  -classpath "$ANDROID_JAR" -d "$CLS" @"$WORK/srcs.txt"

echo "== d8 =="
find "$CLS" -name "*.class" > "$WORK/classfiles.txt"
d8 --release --lib "$ANDROID_JAR" --output "$WORK" @"$WORK/classfiles.txt"
[ -f "$WORK/classes.dex" ] || { echo "classes.dex missing"; exit 1; }

echo "== add dex into apk (python zipfile - no aapt1 'add' on Termux) =="
python3 - "$WORK/base.apk" "$WORK/classes.dex" << 'PYEOF'
import sys, zipfile
apk, dex = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(apk, "a", zipfile.ZIP_DEFLATED) as zf:
    zf.write(dex, "classes.dex")
PYEOF

echo "== pack web assets (forward slashes) =="
python3 "$ROOT/scripts/pack_apk_assets.py" "$WORK/base.apk" "$WEB"

echo "== zipalign: SKIPPED (see header comment) =="
cp "$WORK/base.apk" "$WORK/aligned.apk"

echo "== sign =="
KS_DIR="$AND/keystore"
mkdir -p "$KS_DIR"
KS="$KS_DIR/ryza.keystore"
if [ ! -f "$KS" ]; then
  "$JDK17/bin/keytool" -genkeypair -v -keystore "$KS" -alias ryza \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Ryza Chat, OU=offline rebuild" -storepass ryza-chat -keypass ryza-chat
fi
APK="$OUT/RyzaChat-$VER.apk"
apksigner sign --ks "$KS" --ks-pass pass:ryza-chat --key-pass pass:ryza-chat \
  --out "$APK" "$WORK/aligned.apk"

echo "== verify =="
apksigner verify "$APK"

echo "== privacy gate on the signed APK =="
python3 "$ROOT/scripts/privacy_check.py" --quiet "$APK"

MB=$(du -m "$APK" | cut -f1)
echo "Built: $APK  (~${MB} MB)"
