import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_node/p2p/call_service.dart';

class _FakeSource {
  final String id;
  final String type;
  const _FakeSource(this.id, this.type);
}

void main() {
  group('choosePreferredDesktopSource', () {
    test('returns null on empty list', () {
      final picked = choosePreferredDesktopSource(const []);
      expect(picked, isNull);
    });

    test('prefers source with screen-like type', () {
      final sources = [
        const _FakeSource('w1', 'window'),
        const _FakeSource('s1', 'screen'),
      ];
      final picked = choosePreferredDesktopSource(sources) as _FakeSource;
      expect(picked.id, 's1');
    });

    test('falls back to first when no screen source', () {
      final sources = [
        const _FakeSource('w1', 'window'),
        const _FakeSource('w2', 'window'),
      ];
      final picked = choosePreferredDesktopSource(sources) as _FakeSource;
      expect(picked.id, 'w1');
    });
  });
}
