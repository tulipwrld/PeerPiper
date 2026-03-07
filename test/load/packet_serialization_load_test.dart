import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_node/p2p/packet.dart';

void main() {
  test('packet serialization load baseline', () {
    const n = 20000;
    final sw = Stopwatch()..start();

    var totalBytes = 0;
    for (var i = 0; i < n; i++) {
      final bytes = PacketBuilder.serialise({
        'kind': 'ping',
        'sender_id': 'node_a',
        'sender_name': 'A',
        'seq': i,
      });
      totalBytes += bytes.length;
    }

    sw.stop();
    expect(totalBytes, greaterThan(0));
    // Guardrail: this should be comfortably below this on dev machines.
    expect(sw.elapsedMilliseconds, lessThan(15000));
  });
}
