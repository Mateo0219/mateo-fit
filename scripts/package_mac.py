import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

binary, app = Path(sys.argv[1]), Path(sys.argv[2])
root = Path(__file__).resolve().parents[1]
(app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
(app / 'Contents/Resources').mkdir(exist_ok=True)
shutil.copy2(binary, app / 'Contents/MacOS/XuXuDesktop')
with tempfile.TemporaryDirectory() as temp:
    icons = Path(temp) / 'AppIcon.iconset'; icons.mkdir()
    original = root / 'Sources/FitnessApp/Assets.xcassets/AppIcon.appiconset/icon.png'
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
            subprocess.run(['sips', '-z', str(size * scale), str(size * scale), str(original), '--out', str(icons / name)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['iconutil', '-c', 'icns', str(icons), '-o', str(app / 'Contents/Resources/AppIcon.icns')], check=True)
shutil.copy2(root / 'Sources/FitnessApp/Assets.xcassets/BrandMark.imageset/mark.png', app / 'Contents/Resources/BrandMark.png')
info = {'CFBundleExecutable': 'XuXuDesktop', 'CFBundleIdentifier': 'com.personal.xuxu.desktop',
        'CFBundleName': 'Mateo Fit', 'CFBundleDisplayName': 'Mateo Fit', 'CFBundlePackageType': 'APPL',
        'CFBundleIconFile': 'AppIcon', 'CFBundleVersion': '22', 'CFBundleShortVersionString': '0.11.1',
        'LSMinimumSystemVersion': '14.0', 'NSHighResolutionCapable': True}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
# Remove only generated Finder metadata that codesign cannot seal. Preserve quarantine and other security attributes.
for item in [app, *app.rglob('*')]:
    for attribute in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
        if subprocess.run(['xattr', '-p', attribute, str(item)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            subprocess.run(['xattr', '-d', attribute, str(item)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
print('Packaged local development app:', app)
