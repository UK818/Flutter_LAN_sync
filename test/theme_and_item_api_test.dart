import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_lan_sync/flutter_lan_sync.dart';

void main() {
  test('LanSyncTheme accepts partial host palettes', () {
    const theme = LanSyncTheme(
      primary: Colors.teal,
      background: Colors.white,
    );

    expect(theme.primary, Colors.teal);
    expect(theme.background, Colors.white);
    expect(theme.warning, isNull);
  });

  test('LanSyncItem supports dynamic payload metadata', () {
    const item = LanSyncItem(
      id: 'record-1',
      displayName: 'Record 1',
      dataType: 'custom_record',
      data: {
        'number': 42,
        'nested': {'enabled': true},
        'values': ['a', 'b'],
      },
    );

    expect(item.dataType, 'custom_record');
    expect(item.data['number'], 42);
    expect((item.data['nested'] as Map)['enabled'], isTrue);
  });
}
