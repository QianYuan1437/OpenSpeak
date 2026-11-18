/// Recognizes popular wireless / creator microphones from the OS device name
/// so OpenSpeak can prefer them automatically and show tailored tips.
///
/// All of these enumerate as standard USB Audio Class (or Bluetooth) inputs,
/// so no vendor driver is needed; what differs is naming, channel layout
/// (dual-transmitter kits put TX1/TX2 on left/right in stereo mode) and gain.
class MicBrand {
  const MicBrand(this.name, this.keywords, this.tipZh, this.tipEn,
      {this.stereoDual = false});

  final String name;
  final List<String> keywords;
  final String tipZh;
  final String tipEn;

  /// Dual-transmitter kit whose stereo mode splits TX1/TX2 into L/R.
  final bool stereoDual;
}

const kMicBrands = <MicBrand>[
  MicBrand(
    'DJI Mic',
    ['dji', 'mic mini', 'mic 2', 'mic 3', 'osmo', 'wireless microphone rx'],
    '已识别 DJI 无线麦克风。双发射器在“立体声”模式下，TX1/TX2 分别在左/右声道，可在下方“声道”中单独选择。',
    'DJI wireless mic detected. In stereo mode TX1/TX2 are on left/right — pick one under "Channel".',
    stereoDual: true,
  ),
  MicBrand(
    'Godox',
    ['godox', 'movelink', 'virso', 'wec', 'cube-s', 'mtx'],
    '已识别神牛 Godox 无线麦克风。若声音偏小，可开启自动增益或调高增益。',
    'Godox wireless mic detected. Enable auto gain if the level is low.',
    stereoDual: true,
  ),
  MicBrand(
    'Insta360 Mic',
    ['insta360', 'mic air', 'mic pro'],
    '已识别影石 Insta360 麦克风。蓝牙连接时请保持接收端靠近设备以减少断续。',
    'Insta360 mic detected. Keep it close when connected over Bluetooth.',
  ),
  MicBrand(
    'RØDE',
    ['rode', 'røde', 'wireless go', 'wireless pro', 'wireless me', 'videomic'],
    '已识别 RØDE 麦克风。',
    'RØDE microphone detected.',
    stereoDual: true,
  ),
  MicBrand(
    'Hollyland',
    ['hollyland', 'lark'],
    '已识别 Hollyland 无线麦克风。',
    'Hollyland wireless mic detected.',
    stereoDual: true,
  ),
  MicBrand('Saramonic', ['saramonic', 'blink'], '已识别 Saramonic 麦克风。',
      'Saramonic microphone detected.',
      stereoDual: true),
  MicBrand('BOYA', ['boya', 'by-v', 'by-wm', 'boyalink', 'boyamic'],
      '已识别 BOYA 麦克风。', 'BOYA microphone detected.',
      stereoDual: true),
  MicBrand('Comica', ['comica', 'vimo'], '已识别 Comica 麦克风。',
      'Comica microphone detected.'),
  MicBrand('Shure', ['shure', 'mv7', 'mv6', 'mv88', 'movemic'],
      '已识别 Shure 麦克风。', 'Shure microphone detected.'),
  MicBrand('Sennheiser', ['sennheiser', 'xs wireless', 'profile usb'],
      '已识别森海塞尔麦克风。', 'Sennheiser microphone detected.'),
  MicBrand(
    '无线麦克风',
    ['wireless mic', 'wireless microphone', 'wireless rx', ' rx'],
    '已识别无线麦克风接收器。',
    'Wireless microphone receiver detected.',
  ),
];

MicBrand? detectMicBrand(String label) {
  final l = ' ${label.toLowerCase()}';
  for (final b in kMicBrands) {
    if (b.keywords.any(l.contains)) return b;
  }
  return null;
}

/// Ranks devices so external creator mics win over built-in arrays.
int micPreference(String label) {
  if (detectMicBrand(label) != null) return 3;
  final l = label.toLowerCase();
  if (l.contains('usb') || l.contains('bluetooth') || l.contains('headset')) {
    return 2;
  }
  if (l.contains('monitor of')) return -1; // PulseAudio loopback sources
  return 1;
}
