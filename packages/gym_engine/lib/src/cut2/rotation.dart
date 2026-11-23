/// Reorder workouts in a week as a rotation (plan R5 option (a), Ricki N1):
/// an ordered list of workout type ids, the next one suggested, which he can
/// drag and skip. No calendar week: recovery logic is untouched.
///
/// Stored by the engine as setting key [rotationSettingKey] =
/// `{"order": [...], "next": n}` (t5z, 23-Nov). Immutable; every change
/// returns a new [Rotation].
library;

const String rotationSettingKey = 'rotation';

/// Default when he has never set one: the classic split.
const List<String> defaultRotationOrder = ['push', 'pull', 'legs'];

class Rotation {
  /// Normalises: drops duplicates (first wins) and empty ids, and wraps
  /// [next] into range. An empty order is allowed (rotation off).
  factory Rotation(List<String> order, {int next = 0}) {
    final seen = <String>{};
    final clean = [
      for (final id in order)
        if (id.isNotEmpty && seen.add(id)) id,
    ];
    return Rotation._(
      List.unmodifiable(clean),
      clean.isEmpty ? 0 : next % clean.length,
    );
  }

  const Rotation._(this.order, this.next);

  factory Rotation.defaults() => Rotation(defaultRotationOrder);

  final List<String> order;

  /// Index into [order] of the suggested next workout.
  final int next;

  bool get isEmpty => order.isEmpty;

  /// The suggested workout type id, or null when the rotation is empty.
  String? get nextId => order.isEmpty ? null : order[next];

  /// The order as he will see it, starting at the next one.
  List<String> get upcoming => [
    for (var i = 0; i < order.length; i++) order[(next + i) % order.length],
  ];

  /// He finished a workout of [typeId]. If it is in the rotation, the next
  /// suggestion is the one after it (so doing Legs instead of Push moves the
  /// pointer past Legs: he picks up from what he actually did). A workout
  /// outside the rotation (mixed pick, null) leaves it unchanged.
  Rotation completed(String? typeId) {
    final i = typeId == null ? -1 : order.indexOf(typeId);
    if (i < 0) return this;
    return Rotation._(order, (i + 1) % order.length);
  }

  /// Skips the suggested one without training it.
  Rotation skip() =>
      order.isEmpty ? this : Rotation._(order, (next + 1) % order.length);

  /// Drag: moves the item at [from] to [to] (indices into [order], [to] is
  /// the final position). The suggested type stays the same type.
  Rotation move(int from, int to) {
    if (from < 0 || from >= order.length || to < 0 || to >= order.length) {
      throw RangeError('move $from -> $to in ${order.length}');
    }
    if (from == to) return this;
    final keep = nextId;
    final list = [...order];
    final item = list.removeAt(from);
    list.insert(to, item);
    return Rotation._(List.unmodifiable(list), list.indexOf(keep!));
  }

  /// Makes [typeId] the suggested next one (he taps a row).
  Rotation pointAt(String typeId) {
    final i = order.indexOf(typeId);
    if (i < 0) throw ArgumentError('not in rotation: $typeId');
    return Rotation._(order, i);
  }

  /// Adds [typeId] at the end (no-op if present).
  Rotation add(String typeId) => order.contains(typeId) || typeId.isEmpty
      ? this
      : Rotation([...order, typeId], next: next);

  /// Removes [typeId]. If it was the suggested one, the one after it is
  /// suggested; otherwise the suggestion is unchanged.
  Rotation remove(String typeId) {
    final i = order.indexOf(typeId);
    if (i < 0) return this;
    final list = [...order]..removeAt(i);
    if (list.isEmpty) return Rotation(const []);
    final keep = i == next ? order[(i + 1) % order.length] : nextId!;
    return Rotation._(List.unmodifiable(list), list.indexOf(keep));
  }

  /// Drops ids that are no longer workout types (e.g. a type renamed in a
  /// later build), keeping the suggestion where possible.
  Rotation retainOnly(Set<String> validIds) {
    var r = this;
    for (final id in order) {
      if (!validIds.contains(id)) r = r.remove(id);
    }
    return r;
  }

  Map<String, Object?> toJson() => {'order': order, 'next': next};

  /// Lenient: a malformed stored value falls back to the defaults rather than
  /// breaking the home screen. Use [tryFromJson] to tell the two apart.
  factory Rotation.fromJson(Object? j) => tryFromJson(j) ?? Rotation.defaults();

  static Rotation? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final order = j['order'];
    final next = j['next'];
    if (order is! List || order.any((e) => e is! String)) return null;
    if (next != null && next is! int) return null;
    return Rotation(order.cast<String>(), next: (next as int?) ?? 0);
  }

  @override
  bool operator ==(Object other) =>
      other is Rotation &&
      other.next == next &&
      other.order.length == order.length &&
      [for (var i = 0; i < order.length; i++) other.order[i] == order[i]]
          .every((x) => x);

  @override
  int get hashCode => Object.hash(Object.hashAll(order), next);

  @override
  String toString() => 'Rotation($order, next: $next)';
}
