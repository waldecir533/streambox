from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
manifest = root / "android" / "app" / "src" / "main" / "AndroidManifest.xml"

if not manifest.exists():
    raise SystemExit("AndroidManifest.xml não encontrado. Execute flutter create antes.")

text = manifest.read_text(encoding="utf-8")

if 'android.permission.INTERNET' not in text:
    text = text.replace(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <uses-permission android:name="android.permission.INTERNET" />'
    )

for permission in (
    'android.permission.ACCESS_NETWORK_STATE',
    'android.permission.ACCESS_WIFI_STATE',
    'android.permission.CHANGE_WIFI_MULTICAST_STATE',
    'android.permission.CHANGE_NETWORK_STATE',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
    'android.permission.NEARBY_WIFI_DEVICES',
):
    if permission not in text:
        text = text.replace(
            '<application',
            f'    <uses-permission android:name="{permission}" />\n\n    <application',
            1,
        )

if 'android.permission.ACCESS_FINE_LOCATION' not in text:
    text = text.replace(
        '<application',
        '    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" '
        'android:maxSdkVersion="32" />\n\n    <application',
        1,
    )

text = text.replace(
    '<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />',
    '<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" '
    'android:usesPermissionFlags="neverForLocation" />',
)

if 'com.google.android.gms.cast.framework.OPTIONS_PROVIDER_CLASS_NAME' not in text:
    cast_config = '''
        <meta-data
            android:name="com.google.android.gms.cast.framework.OPTIONS_PROVIDER_CLASS_NAME"
            android:value="com.felnanuke.google_cast.GoogleCastOptionsProvider" />
        <service
            android:name="com.google.android.gms.cast.framework.media.MediaNotificationService"
            android:exported="false"
            android:foregroundServiceType="mediaPlayback" />
'''
    text = text.replace('</application>', f'{cast_config}    </application>')

if 'android:usesCleartextTraffic=' not in text:
    text = re.sub(
        r'<application\s+',
        '<application\n        android:usesCleartextTraffic="true"\n        ',
        text,
        count=1,
    )

text = re.sub(r'android:label="[^"]*"', 'android:label="StreamBox"', text, count=1)
manifest.write_text(text, encoding="utf-8")

kts = root / "android" / "app" / "build.gradle.kts"
groovy = root / "android" / "app" / "build.gradle"

if kts.exists():
    gradle = kts.read_text(encoding="utf-8")
    gradle = gradle.replace("minSdk = flutter.minSdkVersion", "minSdk = 24")
    kts.write_text(gradle, encoding="utf-8")
elif groovy.exists():
    gradle = groovy.read_text(encoding="utf-8")
    gradle = gradle.replace("minSdkVersion flutter.minSdkVersion", "minSdkVersion 24")
    gradle = gradle.replace("minSdkVersion flutter.minSdk", "minSdkVersion 24")
    groovy.write_text(gradle, encoding="utf-8")
else:
    raise SystemExit("Arquivo Gradle do app não encontrado.")

print("Android configurado: rede, Google Cast, HTTP cleartext, minSdk 24 e nome StreamBox.")
