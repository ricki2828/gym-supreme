import 'package:gym_engine/src/cut2/rotation.dart';
import 'package:gym_engine/src/cut2/rotation_store.dart';
import 'package:gym_engine/src/store.dart';
import 'package:test/test.dart';

void main() {
  test('nothing stored: defaults; finish advances and persists', () {
    final store = MemoryStore();
    expect(loadRotation(store), Rotation.defaults());
    final r = rotationAfterFinish(store, 'push');
    expect(r.nextId, 'pull');
    expect(
      store.setting('rotation'),
      '{"order":["push","pull","legs"],"next":1}',
    );
    expect(loadRotation(store).nextId, 'pull');
  });

  test('mixed pick or outside type: nothing written', () {
    final store = MemoryStore();
    rotationAfterFinish(store, null);
    rotationAfterFinish(store, 'engine');
    expect(store.setting('rotation'), isNull);
  });

  test('garbled or stale stored value is survivable', () {
    final store = MemoryStore();
    store.saveSetting('rotation', 'not json');
    expect(loadRotation(store), Rotation.defaults());
    store.saveSetting('rotation', '{"order":["legs","gone","core"],"next":1}');
    final r = loadRotation(store);
    expect(r.order, ['legs', 'core']);
    expect(r.nextId, 'core');
  });

  test('only unknown ids stored: defaults; empty on purpose stays empty', () {
    final store = MemoryStore();
    store.saveSetting('rotation', '{"order":["old1","old2"],"next":0}');
    expect(loadRotation(store), Rotation.defaults());
    store.saveSetting('rotation', '{"order":[],"next":0}');
    expect(loadRotation(store).isEmpty, isTrue);
  });

  test('drag then save round-trips', () {
    final store = MemoryStore();
    saveRotation(store, Rotation.defaults().onReorder(0, 3));
    expect(loadRotation(store).order, ['pull', 'legs', 'push']);
  });
}
