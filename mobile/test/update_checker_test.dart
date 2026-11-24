import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/update/update_checker.dart';

void main() {
  group('compareVersions', () {
    test('build number decides within the same version', () {
      expect(compareVersions('1.0.0+4', '1.0.0+3'), greaterThan(0));
      expect(compareVersions('1.0.0+3', '1.0.0+4'), lessThan(0));
      expect(compareVersions('1.0.0+3', '1.0.0+3'), 0);
    });

    test('version parts outrank the build number', () {
      expect(compareVersions('1.0.1+1', '1.0.0+9'), greaterThan(0));
      expect(compareVersions('1.1.0+1', '1.0.9+9'), greaterThan(0));
      expect(compareVersions('2.0.0+1', '1.9.9+9'), greaterThan(0));
    });

    test('a leading v and a missing build are tolerated', () {
      expect(compareVersions('v1.0.0+4', '1.0.0+4'), 0);
      expect(compareVersions('1.0.0', '1.0.0+0'), 0);
      expect(compareVersions('v1.2.3', '1.2.2+7'), greaterThan(0));
    });

    test('unparsable input compares equal instead of crashing', () {
      expect(compareVersions('nonsense', '1.0.0+1'), 0);
      expect(compareVersions('1.0.0+1', ''), 0);
    });
  });

  group('ReleaseInfo', () {
    test('version strips the leading v from the tag', () {
      const info = ReleaseInfo(
        tag: 'v1.0.0+4',
        notes: '',
        apkUrl: 'https://example.invalid/app-release.apk',
        apkSize: 1,
        sumsUrl: '',
      );
      expect(info.version, '1.0.0+4');
    });
  });
}
