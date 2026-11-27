import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/lit_widgets.dart';
import 'progress_model.dart';

/// Profile: birth year, sex, bodyweight log. Local only (one `profile`
/// setting on this phone); nothing is sent anywhere. Every change is saved
/// at once through [onSave].
class SettingsProfileScreen extends StatefulWidget {
  const SettingsProfileScreen({
    super.key,
    required this.initial,
    required this.today,
    required this.onSave,
  });

  final Profile initial;

  /// Today's local date, "YYYY-MM-DD".
  final String today;
  final void Function(Profile profile) onSave;

  @override
  State<SettingsProfileScreen> createState() => _SettingsProfileScreenState();
}

class _SettingsProfileScreenState extends State<SettingsProfileScreen> {
  late Profile _p = widget.initial;
  late final TextEditingController _year = TextEditingController(
    text: _p.birthYear?.toString() ?? '',
  );
  final TextEditingController _kg = TextEditingController();
  late String _date = widget.today;
  String? _yearError;
  String? _kgError;

  @override
  void dispose() {
    _year.dispose();
    _kg.dispose();
    super.dispose();
  }

  void _set(Profile p) {
    setState(() => _p = p);
    widget.onSave(p);
  }

  int get _thisYear => int.parse(widget.today.substring(0, 4));

  void _saveYear() {
    final t = _year.text.trim();
    if (t.isEmpty) {
      setState(() => _yearError = null);
      _set(_p.copyWith(birthYear: null));
      return;
    }
    if (t.length < 4) {
      setState(() => _yearError = null);
      return;
    }
    final y = int.tryParse(t);
    if (y == null || y < _thisYear - 110 || y > _thisYear - 10) {
      setState(() => _yearError = 'Enter a year like 1990');
      return;
    }
    setState(() => _yearError = null);
    _set(_p.copyWith(birthYear: y));
  }

  void _addWeighIn() {
    final v = double.tryParse(_kg.text.trim().replaceAll(',', '.'));
    if (v == null || v < 20 || v > 400) {
      setState(() => _kgError = 'Enter your weight in kg, like 82.5');
      return;
    }
    setState(() => _kgError = null);
    _kg.clear();
    _set(_p.withWeighIn(_date, (v * 1000).round()));
  }

  Future<void> _pickDate() async {
    final now = DateTime.parse(widget.today);
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_date),
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (d != null) setState(() => _date = isoDate(d));
  }

  @override
  Widget build(BuildContext context) {
    final log = _p.log.reversed.toList();
    return Scaffold(
      backgroundColor: Lit.ground,
      appBar: AppBar(
        backgroundColor: Lit.ground,
        elevation: 0,
        iconTheme: const IconThemeData(color: Lit.ink),
        title: Text('PROFILE', style: LitType.display(30)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            Text(
              'Stays on this phone. Used only to show your lifts against '
              'your bodyweight.',
              style: LitType.body(14, Lit.inkSecondary),
            ),
            const SizedBox(height: 18),
            Text('BIRTH YEAR', style: LitType.display(22)),
            const SizedBox(height: 6),
            TextField(
              key: const Key('profile.year'),
              controller: _year,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: InputDecoration(
                counterText: '',
                hintText: 'Optional',
                errorText: _yearError,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => _saveYear(),
            ),
            const SizedBox(height: 14),
            Text('SEX', style: LitType.display(22)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final (id, label) in const [
                  ('male', 'Male'),
                  ('female', 'Female'),
                  (null, 'Skip'),
                ])
                  ChoiceChip(
                    key: Key('profile.sex.${id ?? 'skip'}'),
                    label: Text(label),
                    selected: _p.sex == id,
                    onSelected: (_) => _set(_p.copyWith(sex: id)),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            Text('BODYWEIGHT', style: LitType.display(22)),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('profile.kg'),
                    controller: _kg,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'kg',
                      errorText: _kgError,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const Key('profile.date'),
                  onPressed: _pickDate,
                  child: Text(dateLabel(_date, today: widget.today)),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('profile.add'),
                  onPressed: _addWeighIn,
                  child: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (log.isEmpty)
              Text(
                'No weigh-ins yet.',
                style: LitType.body(14, Lit.inkSecondary),
              )
            else
              for (final e in log)
                Container(
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Lit.hair)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${kgText(e.kg)} kg · ${dateLabel(e.date, today: widget.today)}',
                          style: LitType.body(15, Lit.ink, FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        key: Key('profile.remove.${e.date}'),
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close),
                        onPressed: () => _set(_p.withoutWeighIn(e.date)),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
