import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// 表情格子边长（emoji 画板框，视觉字号 [_emojiFont]）。
const double _cellSize = 32;

/// 表情字面的字号（比格子小一圈，四周留呼吸）。
const double _emojiFont = 20;

/// 把 [emoji] 插进 [controller] 的光标处（替换选区），光标移到插入之后。
///
/// 无有效光标（没点进过标题）⇒ 插到**开头**当首个字符——表情是标题的图标位
/// （Notion 同款：emoji 总在最前）。
///
/// ⚠️ 外部改 [TextEditingController.value] **不会**触发 `TextField.onChanged`
/// ⇒ 调用方必须随后自己触发落盘（[onChanged] 那条防抖）。
void insertEmojiAtCursor(TextEditingController controller, String emoji) {
  final TextSelection sel = controller.selection;
  final String text = controller.text;
  if (!sel.isValid) {
    final String next = emoji + text;
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: emoji.length),
    );
    return;
  }
  final int start = sel.start.clamp(0, text.length);
  final int end = sel.end.clamp(0, text.length);
  final String next = text.replaceRange(start, end, emoji);
  controller.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: start + emoji.length),
  );
}

/// 一枚表情：字符 + 中文名 + 检索关键词（英文，小写空格分隔）。
///
/// 搜索按 字符 / 中文名 / 关键词 三者匹配（子串、大小写不敏感）。
class EmojiEntry {
  const EmojiEntry(this.char, this.name, [this.keywords = '']);

  /// 表情字符本体。
  final String char;

  /// 中文名（中文检索用）。
  final String name;

  /// 英文关键词（英文检索用，小写空格分隔）。
  final String keywords;

  /// 是否匹配搜索词 [query]。
  bool matches(String query) {
    final String q = query.toLowerCase().trim();
    if (q.isEmpty) return true;
    return char.contains(q) ||
        name.toLowerCase().contains(q) ||
        keywords.toLowerCase().contains(q);
  }
}

/// 一个表情分类：图标 emoji + 标签 + 其下的表情。
class EmojiCategory {
  const EmojiCategory(this.icon, this.label, this.entries);

  /// 分类 Tab 上的代表 emoji。
  final String icon;

  /// 分类标签（中文，tooltip / 读屏用）。
  final String label;

  /// 该分类下的表情。
  final List<EmojiEntry> entries;
}

/// 标题表情选择器：分类 Tab + 搜索 + 扁平网格
/// （Bauhaus 硬边 4px、hover 热区高亮、无投影）。
///
/// 纯内存常量、不引 emoji 包、不落盘 Recent——**克制与视觉统一优先**。
/// 8 分类 200+ 表情，分类 Tab 切换 + 顶部搜索（中文名 / 英文关键词 / 字符）。
///
/// 由 [AppPopover]（`lib/src/theme/app_popover.dart`）承载为锚定浮层；
/// [width] 喂给它的 `panelWidth`（定位要靠已知宽度把面板钳进屏幕内）。
class EmojiPickerPanel extends StatefulWidget {
  const EmojiPickerPanel({super.key, required this.onPick});

  /// 面板固定宽度：8 列 × [_cellSize] + 7 缝 + 两侧 [Tokens.spaceMd] 内距。
  static const double width =
      _cellSize * 8 + Tokens.spaceXs * 7 + Tokens.spaceMd * 2;

  /// 选中一个表情的回调（表情字符本身）。
  final ValueChanged<String> onPick;

  /// 8 分类、200+ 表情（中文名 + 英文关键词）。
  static const List<EmojiCategory> categories = <EmojiCategory>[
    // ── 笑脸 ──
    EmojiCategory('😀', '笑脸', <EmojiEntry>[
      EmojiEntry('😀', '开心', 'smile happy'),
      EmojiEntry('😁', '笑脸', 'grin'),
      EmojiEntry('😂', '笑哭', 'joy laugh'),
      EmojiEntry('🤣', '捧腹', 'rofl'),
      EmojiEntry('😊', '微笑', 'smile blush'),
      EmojiEntry('😇', '天使', 'angel innocent'),
      EmojiEntry('🙂', '淡笑', 'slight smile'),
      EmojiEntry('😉', '眨眼', 'wink'),
      EmojiEntry('😍', '花痴', 'love heart eyes'),
      EmojiEntry('🥰', '喜爱', 'love adore'),
      EmojiEntry('😘', '飞吻', 'kiss'),
      EmojiEntry('😗', '亲亲', 'kiss'),
      EmojiEntry('😋', '好吃', 'yum delicious'),
      EmojiEntry('😛', '吐舌', 'tongue'),
      EmojiEntry('😜', '调皮', 'playful wink'),
      EmojiEntry('🤪', '滑稽', 'zany crazy'),
      EmojiEntry('🤨', '怀疑', 'suspect eyebrow'),
      EmojiEntry('🤓', '书呆', 'nerd'),
      EmojiEntry('😎', '酷', 'cool sunglasses'),
      EmojiEntry('🥳', '庆祝', 'celebrate party'),
      EmojiEntry('😏', '得意', 'smug'),
      EmojiEntry('😒', '不爽', 'unamused'),
      EmojiEntry('😞', '失望', 'disappointed'),
      EmojiEntry('😔', '忧郁', 'pensive sad'),
      EmojiEntry('😢', '哭泣', 'cry'),
      EmojiEntry('😭', '大哭', 'cry sob'),
      EmojiEntry('😤', '傲慢', 'triumph'),
      EmojiEntry('😠', '生气', 'angry'),
      EmojiEntry('😡', '愤怒', 'rage'),
      EmojiEntry('🤬', '骂人', 'curse'),
      EmojiEntry('🤯', '爆炸头', 'explode mind'),
      EmojiEntry('😳', '脸红', 'blush flush'),
      EmojiEntry('🥵', '热', 'hot'),
      EmojiEntry('🥶', '冷', 'cold freezing'),
      EmojiEntry('😱', '惊恐', 'scream fear'),
      EmojiEntry('😨', '害怕', 'fear'),
      EmojiEntry('😰', '焦虑', 'anxiety sweat'),
      EmojiEntry('🤗', '抱抱', 'hug'),
      EmojiEntry('🤔', '思考', 'think'),
      EmojiEntry('🤭', '偷笑', 'giggle'),
      EmojiEntry('🤫', '嘘', 'shush quiet'),
      EmojiEntry('🤥', '撒谎', 'lying'),
      EmojiEntry('😶', '无语', 'speechless'),
      EmojiEntry('😐', '面无表情', 'neutral'),
      EmojiEntry('😑', '郁闷', 'annoyed'),
      EmojiEntry('😬', '尴尬', 'awkward grimace'),
      EmojiEntry('🙄', '翻白眼', 'eyeroll'),
      EmojiEntry('😴', '睡觉', 'sleep'),
      EmojiEntry('🤤', '流口水', 'drool'),
      EmojiEntry('😪', '困倦', 'sleepy'),
      EmojiEntry('😮', '惊讶', 'surprise'),
      EmojiEntry('😲', '震惊', 'shock'),
      EmojiEntry('🥱', '打哈欠', 'yawn'),
      EmojiEntry('😵', '昏迷', 'dizzy'),
      EmojiEntry('😷', '口罩', 'mask'),
      EmojiEntry('🤒', '发烧', 'fever'),
      EmojiEntry('🤕', '受伤', 'injury'),
      EmojiEntry('🤢', '恶心', 'nauseous'),
      EmojiEntry('🤮', '呕吐', 'vomit'),
      EmojiEntry('🤧', '打喷嚏', 'sneeze'),
      EmojiEntry('😈', '小恶魔', 'devil'),
      EmojiEntry('👿', '恶魔', 'devil angry'),
      EmojiEntry('💀', '骷髅', 'skull'),
      EmojiEntry('💩', '便便', 'poop'),
      EmojiEntry('👻', '鬼', 'ghost'),
      EmojiEntry('👽', '外星人', 'alien'),
      EmojiEntry('🤖', '机器人', 'robot'),
    ]),

    // ── 手势 / 人物 ──
    EmojiCategory('👋', '手势', <EmojiEntry>[
      EmojiEntry('👋', '挥手', 'wave hello'),
      EmojiEntry('🤚', '手背', 'back of hand'),
      EmojiEntry('✋', '停', 'stop hand'),
      EmojiEntry('🖖', '瓦肯', 'vulcan'),
      EmojiEntry('👌', '好的', 'ok perfect'),
      EmojiEntry('🤌', '捏', 'pinch'),
      EmojiEntry('✌️', '胜利', 'peace victory'),
      EmojiEntry('🤞', '祈祷', 'cross fingers'),
      EmojiEntry('🤟', '爱你', 'love you'),
      EmojiEntry('🤘', '摇滚', 'rock metal'),
      EmojiEntry('🤙', '打电话', 'call'),
      EmojiEntry('👆', '上指', 'point up'),
      EmojiEntry('👇', '下指', 'point down'),
      EmojiEntry('👈', '左指', 'point left'),
      EmojiEntry('👉', '右指', 'point right'),
      EmojiEntry('👍', '赞', 'thumbsup like'),
      EmojiEntry('👎', '踩', 'thumbsdown dislike'),
      EmojiEntry('✊', '拳头', 'fist'),
      EmojiEntry('👊', '出拳', 'punch'),
      EmojiEntry('👏', '鼓掌', 'clap applause'),
      EmojiEntry('🙌', '欢呼', 'hooray hands'),
      EmojiEntry('🤲', '捧', 'palms up'),
      EmojiEntry('🤝', '握手', 'handshake'),
      EmojiEntry('🙏', '拜托', 'pray please'),
      EmojiEntry('💪', '肌肉', 'muscle strong'),
      EmojiEntry('🦾', '机械臂', 'robot arm'),
      EmojiEntry('✍️', '写字', 'writing'),
      EmojiEntry('💅', '指甲', 'nails'),
      EmojiEntry('👀', '眼睛', 'eyes'),
      EmojiEntry('🧠', '大脑', 'brain'),
      EmojiEntry('🫀', '心脏', 'heart organ'),
      EmojiEntry('🫁', '肺', 'lungs'),
      EmojiEntry('👶', '婴儿', 'baby'),
      EmojiEntry('🧒', '小孩', 'child'),
      EmojiEntry('👦', '男孩', 'boy'),
      EmojiEntry('👧', '女孩', 'girl'),
      EmojiEntry('👨', '男人', 'man'),
      EmojiEntry('👩', '女人', 'woman'),
      EmojiEntry('🧓', '老人', 'elder'),
      EmojiEntry('🙋', '举手', 'raise hand'),
      EmojiEntry('🤷', '耸肩', 'shrug'),
      EmojiEntry('🤦', '扶额', 'facepalm'),
      EmojiEntry('🙇', '鞠躬', 'bow'),
      EmojiEntry('🏃', '跑步', 'run'),
      EmojiEntry('🚶', '走路', 'walk'),
      EmojiEntry('💃', '跳舞', 'dance'),
      EmojiEntry('🕺', '街舞', 'dance man'),
    ]),

    // ── 动物 / 自然 ──
    EmojiCategory('🐶', '动物', <EmojiEntry>[
      EmojiEntry('🐶', '狗', 'dog puppy'),
      EmojiEntry('🐱', '猫', 'cat'),
      EmojiEntry('🐭', '老鼠', 'mouse'),
      EmojiEntry('🐹', '仓鼠', 'hamster'),
      EmojiEntry('🐰', '兔子', 'rabbit bunny'),
      EmojiEntry('🦊', '狐狸', 'fox'),
      EmojiEntry('🐻', '熊', 'bear'),
      EmojiEntry('🐼', '熊猫', 'panda'),
      EmojiEntry('🐨', '考拉', 'koala'),
      EmojiEntry('🐯', '老虎', 'tiger'),
      EmojiEntry('🦁', '狮子', 'lion'),
      EmojiEntry('🐮', '牛', 'cow'),
      EmojiEntry('🐷', '猪', 'pig'),
      EmojiEntry('🐸', '青蛙', 'frog'),
      EmojiEntry('🐵', '猴子', 'monkey'),
      EmojiEntry('🐔', '鸡', 'chicken'),
      EmojiEntry('🐧', '企鹅', 'penguin'),
      EmojiEntry('🐦', '小鸟', 'bird'),
      EmojiEntry('🐤', '小鸡', 'chick'),
      EmojiEntry('🦆', '鸭子', 'duck'),
      EmojiEntry('🦅', '老鹰', 'eagle'),
      EmojiEntry('🦉', '猫头鹰', 'owl'),
      EmojiEntry('🦇', '蝙蝠', 'bat'),
      EmojiEntry('🐺', '狼', 'wolf'),
      EmojiEntry('🐗', '野猪', 'boar'),
      EmojiEntry('🐴', '马', 'horse'),
      EmojiEntry('🦄', '独角兽', 'unicorn'),
      EmojiEntry('🐝', '蜜蜂', 'bee'),
      EmojiEntry('🐛', '毛毛虫', 'bug'),
      EmojiEntry('🦋', '蝴蝶', 'butterfly'),
      EmojiEntry('🐌', '蜗牛', 'snail'),
      EmojiEntry('🐞', '瓢虫', 'ladybug'),
      EmojiEntry('🐜', '蚂蚁', 'ant'),
      EmojiEntry('🕷️', '蜘蛛', 'spider'),
      EmojiEntry('🐢', '乌龟', 'turtle'),
      EmojiEntry('🐍', '蛇', 'snake'),
      EmojiEntry('🦎', '蜥蜴', 'lizard'),
      EmojiEntry('🐙', '章鱼', 'octopus'),
      EmojiEntry('🦑', '鱿鱼', 'squid'),
      EmojiEntry('🦐', '虾', 'shrimp'),
      EmojiEntry('🦀', '螃蟹', 'crab'),
      EmojiEntry('🐠', '热带鱼', 'tropical fish'),
      EmojiEntry('🐟', '鱼', 'fish'),
      EmojiEntry('🐬', '海豚', 'dolphin'),
      EmojiEntry('🐳', '鲸鱼', 'whale'),
      EmojiEntry('🦈', '鲨鱼', 'shark'),
      EmojiEntry('🌸', '樱花', 'cherry blossom'),
      EmojiEntry('🌹', '玫瑰', 'rose'),
      EmojiEntry('🌻', '向日葵', 'sunflower'),
      EmojiEntry('🌷', '郁金香', 'tulip'),
      EmojiEntry('🌺', '木槿', 'hibiscus'),
      EmojiEntry('🍀', '四叶草', 'clover luck'),
      EmojiEntry('🍁', '枫叶', 'maple leaf'),
      EmojiEntry('🍂', '落叶', 'fallen leaf'),
      EmojiEntry('🌿', '草药', 'herb'),
      EmojiEntry('🌱', '幼苗', 'seedling'),
      EmojiEntry('🌲', '松树', 'evergreen tree'),
      EmojiEntry('🌳', '大树', 'tree'),
      EmojiEntry('🌵', '仙人掌', 'cactus'),
      EmojiEntry('☀️', '太阳', 'sun'),
      EmojiEntry('🌙', '月亮', 'moon'),
      EmojiEntry('⭐', '星星', 'star'),
      EmojiEntry('🌟', '亮星', 'glowing star'),
      EmojiEntry('🌈', '彩虹', 'rainbow'),
      EmojiEntry('🔥', '火', 'fire hot'),
      EmojiEntry('💧', '水滴', 'water drop'),
    ]),

    // ── 食物 / 饮品 ──
    EmojiCategory('🍔', '食物', <EmojiEntry>[
      EmojiEntry('🍎', '苹果', 'apple'),
      EmojiEntry('🍊', '橙子', 'orange'),
      EmojiEntry('🍋', '柠檬', 'lemon'),
      EmojiEntry('🍌', '香蕉', 'banana'),
      EmojiEntry('🍉', '西瓜', 'watermelon'),
      EmojiEntry('🍇', '葡萄', 'grapes'),
      EmojiEntry('🍓', '草莓', 'strawberry'),
      EmojiEntry('🫐', '蓝莓', 'blueberry'),
      EmojiEntry('🍑', '桃子', 'peach'),
      EmojiEntry('🍒', '樱桃', 'cherry'),
      EmojiEntry('🥭', '芒果', 'mango'),
      EmojiEntry('🍍', '菠萝', 'pineapple'),
      EmojiEntry('🥥', '椰子', 'coconut'),
      EmojiEntry('🥝', '猕猴桃', 'kiwi'),
      EmojiEntry('🍅', '番茄', 'tomato'),
      EmojiEntry('🥑', '牛油果', 'avocado'),
      EmojiEntry('🍆', '茄子', 'eggplant'),
      EmojiEntry('🥦', '西兰花', 'broccoli'),
      EmojiEntry('🥕', '胡萝卜', 'carrot'),
      EmojiEntry('🌽', '玉米', 'corn'),
      EmojiEntry('🌶️', '辣椒', 'chili pepper'),
      EmojiEntry('🥔', '土豆', 'potato'),
      EmojiEntry('🍞', '面包', 'bread'),
      EmojiEntry('🥐', '可颂', 'croissant'),
      EmojiEntry('🧀', '奶酪', 'cheese'),
      EmojiEntry('🥚', '鸡蛋', 'egg'),
      EmojiEntry('🍳', '煎蛋', 'fried egg'),
      EmojiEntry('🥞', '松饼', 'pancake'),
      EmojiEntry('🥓', '培根', 'bacon'),
      EmojiEntry('🍔', '汉堡', 'burger hamburger'),
      EmojiEntry('🍟', '薯条', 'fries'),
      EmojiEntry('🍕', '披萨', 'pizza'),
      EmojiEntry('🌭', '热狗', 'hotdog'),
      EmojiEntry('🥪', '三明治', 'sandwich'),
      EmojiEntry('🌮', '塔可', 'taco'),
      EmojiEntry('🍜', '拉面', 'ramen noodles'),
      EmojiEntry('🍝', '意面', 'spaghetti pasta'),
      EmojiEntry('🍣', '寿司', 'sushi'),
      EmojiEntry('🍤', '炸虾', 'fried shrimp'),
      EmojiEntry('🍚', '米饭', 'rice'),
      EmojiEntry('🥟', '饺子', 'dumpling'),
      EmojiEntry('🍰', '蛋糕', 'cake'),
      EmojiEntry('🎂', '生日蛋糕', 'birthday cake'),
      EmojiEntry('🍪', '饼干', 'cookie'),
      EmojiEntry('🍫', '巧克力', 'chocolate'),
      EmojiEntry('🍬', '糖果', 'candy'),
      EmojiEntry('🍭', '棒棒糖', 'lollipop'),
      EmojiEntry('🍩', '甜甜圈', 'donut'),
      EmojiEntry('🍦', '冰淇淋', 'ice cream'),
      EmojiEntry('☕', '咖啡', 'coffee'),
      EmojiEntry('🍵', '茶', 'tea'),
      EmojiEntry('🧋', '奶茶', 'bubble tea'),
      EmojiEntry('🍺', '啤酒', 'beer'),
      EmojiEntry('🍷', '红酒', 'wine'),
      EmojiEntry('🥂', '干杯', 'cheers'),
    ]),

    // ── 活动 ──
    EmojiCategory('⚽', '活动', <EmojiEntry>[
      EmojiEntry('⚽', '足球', 'soccer football'),
      EmojiEntry('🏀', '篮球', 'basketball'),
      EmojiEntry('🏈', '橄榄球', 'american football'),
      EmojiEntry('⚾', '棒球', 'baseball'),
      EmojiEntry('🎾', '网球', 'tennis'),
      EmojiEntry('🏐', '排球', 'volleyball'),
      EmojiEntry('🎱', '台球', 'billiards pool'),
      EmojiEntry('🏓', '乒乓球', 'ping pong'),
      EmojiEntry('🏸', '羽毛球', 'badminton'),
      EmojiEntry('🥊', '拳击', 'boxing'),
      EmojiEntry('🥋', '武术', 'martial arts'),
      EmojiEntry('⛳', '高尔夫', 'golf'),
      EmojiEntry('⛸️', '溜冰', 'ice skate'),
      EmojiEntry('🎿', '滑雪', 'ski'),
      EmojiEntry('🏂', '单板', 'snowboard'),
      EmojiEntry('🏄', '冲浪', 'surf'),
      EmojiEntry('🏊', '游泳', 'swim'),
      EmojiEntry('🚴', '骑行', 'cycling bike'),
      EmojiEntry('🏆', '奖杯', 'trophy win'),
      EmojiEntry('🥇', '金牌', 'gold medal'),
      EmojiEntry('🥈', '银牌', 'silver medal'),
      EmojiEntry('🥉', '铜牌', 'bronze medal'),
      EmojiEntry('🎯', '靶心', 'target dart'),
      EmojiEntry('🎮', '游戏', 'game controller'),
      EmojiEntry('🎲', '骰子', 'dice random'),
      EmojiEntry('🧩', '拼图', 'puzzle'),
      EmojiEntry('🎨', '调色盘', 'art palette'),
      EmojiEntry('🎭', '戏剧', 'theater masks'),
      EmojiEntry('🎬', '场记板', 'movie clapper'),
      EmojiEntry('🎤', '麦克风', 'microphone sing'),
      EmojiEntry('🎧', '耳机', 'headphones music'),
      EmojiEntry('🎸', '吉他', 'guitar'),
      EmojiEntry('🎹', '钢琴', 'piano keyboard'),
      EmojiEntry('🥁', '鼓', 'drum'),
      EmojiEntry('🎉', '派对', 'party tada'),
      EmojiEntry('🎊', '彩带', 'confetti'),
      EmojiEntry('🎈', '气球', 'balloon'),
      EmojiEntry('🎁', '礼物', 'gift present'),
    ]),

    // ── 旅行 / 地点 ──
    EmojiCategory('🚗', '旅行', <EmojiEntry>[
      EmojiEntry('🚗', '汽车', 'car'),
      EmojiEntry('🚌', '公交', 'bus'),
      EmojiEntry('🚕', '出租车', 'taxi'),
      EmojiEntry('🚙', '越野车', 'suv'),
      EmojiEntry('🚚', '卡车', 'truck'),
      EmojiEntry('🚲', '自行车', 'bicycle'),
      EmojiEntry('🛴', '滑板车', 'scooter'),
      EmojiEntry('🏍️', '摩托车', 'motorcycle'),
      EmojiEntry('🚂', '火车', 'train'),
      EmojiEntry('🚄', '高铁', 'bullet train'),
      EmojiEntry('✈️', '飞机', 'airplane plane'),
      EmojiEntry('🚀', '火箭', 'rocket'),
      EmojiEntry('🚁', '直升机', 'helicopter'),
      EmojiEntry('⛵', '帆船', 'sailboat'),
      EmojiEntry('🚢', '轮船', 'ship'),
      EmojiEntry('⚓', '锚', 'anchor'),
      EmojiEntry('🗺️', '地图', 'map'),
      EmojiEntry('🧭', '指南针', 'compass'),
      EmojiEntry('🏔️', '雪山', 'mountain snow'),
      EmojiEntry('⛰️', '山', 'mountain'),
      EmojiEntry('🌋', '火山', 'volcano'),
      EmojiEntry('🏕️', '露营', 'camping tent'),
      EmojiEntry('🏖️', '海滩', 'beach'),
      EmojiEntry('🏝️', '海岛', 'island'),
      EmojiEntry('🏙️', '城市', 'city skyline'),
      EmojiEntry('🏠', '房子', 'house home'),
      EmojiEntry('🏢', '办公楼', 'office building'),
      EmojiEntry('🏥', '医院', 'hospital'),
      EmojiEntry('🏫', '学校', 'school'),
      EmojiEntry('🏰', '城堡', 'castle'),
      EmojiEntry('🗼', '铁塔', 'tower'),
      EmojiEntry('🗽', '自由女神', 'statue of liberty'),
      EmojiEntry('⛪', '教堂', 'church'),
      EmojiEntry('🕌', '清真寺', 'mosque'),
      EmojiEntry('⛲', '喷泉', 'fountain'),
      EmojiEntry('🌅', '日出', 'sunrise'),
      EmojiEntry('🌇', '日落', 'sunset'),
      EmojiEntry('🌃', '夜景', 'night city'),
    ]),

    // ── 物品 ──
    EmojiCategory('💡', '物品', <EmojiEntry>[
      EmojiEntry('💡', '灯泡', 'idea bulb'),
      EmojiEntry('🔦', '手电', 'flashlight'),
      EmojiEntry('📱', '手机', 'phone mobile'),
      EmojiEntry('💻', '笔记本', 'laptop computer'),
      EmojiEntry('⌨️', '键盘', 'keyboard'),
      EmojiEntry('🖥️', '显示器', 'desktop monitor'),
      EmojiEntry('🖨️', '打印机', 'printer'),
      EmojiEntry('📷', '相机', 'camera'),
      EmojiEntry('🎥', '摄像机', 'video camera'),
      EmojiEntry('📺', '电视', 'tv television'),
      EmojiEntry('📻', '收音机', 'radio'),
      EmojiEntry('⏰', '闹钟', 'alarm clock'),
      EmojiEntry('⌚', '手表', 'watch'),
      EmojiEntry('⏳', '沙漏', 'hourglass'),
      EmojiEntry('🔋', '电池', 'battery'),
      EmojiEntry('🔌', '插头', 'plug'),
      EmojiEntry('💰', '钱袋', 'money bag'),
      EmojiEntry('💵', '钞票', 'dollar cash'),
      EmojiEntry('💳', '银行卡', 'credit card'),
      EmojiEntry('💎', '钻石', 'diamond gem'),
      EmojiEntry('⚖️', '天平', 'scales balance'),
      EmojiEntry('🔧', '扳手', 'wrench tool'),
      EmojiEntry('🔨', '锤子', 'hammer'),
      EmojiEntry('⚙️', '齿轮', 'gear settings'),
      EmojiEntry('🧰', '工具箱', 'toolbox'),
      EmojiEntry('🧲', '磁铁', 'magnet'),
      EmojiEntry('🧪', '试管', 'test tube'),
      EmojiEntry('🔬', '显微镜', 'microscope'),
      EmojiEntry('🔭', '望远镜', 'telescope'),
      EmojiEntry('💊', '药丸', 'pill medicine'),
      EmojiEntry('💉', '针筒', 'syringe injection'),
      EmojiEntry('🚪', '门', 'door'),
      EmojiEntry('🪑', '椅子', 'chair'),
      EmojiEntry('🛏️', '床', 'bed'),
      EmojiEntry('🚿', '淋浴', 'shower'),
      EmojiEntry('🔑', '钥匙', 'key'),
      EmojiEntry('🔒', '锁', 'lock'),
      EmojiEntry('📦', '包裹', 'package box'),
      EmojiEntry('📫', '邮箱', 'mailbox'),
      EmojiEntry('✏️', '铅笔', 'pencil'),
      EmojiEntry('🖊️', '钢笔', 'pen'),
      EmojiEntry('📝', '备忘', 'memo note'),
      EmojiEntry('📚', '书堆', 'books'),
      EmojiEntry('📖', '书', 'open book'),
      EmojiEntry('📰', '报纸', 'newspaper'),
      EmojiEntry('📎', '回形针', 'paperclip'),
      EmojiEntry('✂️', '剪刀', 'scissors'),
      EmojiEntry('🗑️', '垃圾桶', 'trash'),
    ]),

    // ── 符号 ──
    EmojiCategory('✅', '符号', <EmojiEntry>[
      EmojiEntry('✅', '对勾', 'check done yes'),
      EmojiEntry('❌', '叉', 'x cross no'),
      EmojiEntry('❓', '问号', 'question'),
      EmojiEntry('❗', '感叹', 'exclamation'),
      EmojiEntry('⚠️', '警告', 'warning'),
      EmojiEntry('🚫', '禁止', 'prohibited'),
      EmojiEntry('⭕', '圆圈', 'circle'),
      EmojiEntry('💯', '满分', 'hundred perfect'),
      EmojiEntry('✨', '闪耀', 'sparkles'),
      EmojiEntry('💫', '流星', 'dizzy star'),
      EmojiEntry('💥', '爆炸', 'boom collision'),
      EmojiEntry('💦', '汗滴', 'sweat drops'),
      EmojiEntry('💨', '疾风', 'dash wind'),
      EmojiEntry('💬', '气泡', 'speech balloon'),
      EmojiEntry('💭', '想法', 'thought balloon'),
      EmojiEntry('💤', '睡觉', 'zzz sleep'),
      EmojiEntry('➕', '加', 'plus add'),
      EmojiEntry('➖', '减', 'minus subtract'),
      EmojiEntry('➗', '除', 'divide'),
      EmojiEntry('✖️', '乘', 'multiply'),
      EmojiEntry('♾️', '无限', 'infinity'),
      EmojiEntry('💲', '美元', 'dollar'),
      EmojiEntry('™️', '商标', 'trademark tm'),
      EmojiEntry('©️', '版权', 'copyright'),
      EmojiEntry('®️', '注册', 'registered'),
      EmojiEntry('🔴', '红点', 'red circle'),
      EmojiEntry('🟠', '橙点', 'orange circle'),
      EmojiEntry('🟡', '黄点', 'yellow circle'),
      EmojiEntry('🟢', '绿点', 'green circle'),
      EmojiEntry('🔵', '蓝点', 'blue circle'),
      EmojiEntry('🟣', '紫点', 'purple circle'),
      EmojiEntry('⚫', '黑点', 'black circle'),
      EmojiEntry('⚪', '白点', 'white circle'),
      EmojiEntry('🔺', '红三角', 'red triangle'),
      EmojiEntry('🔻', '倒三角', 'down triangle'),
      EmojiEntry('🔶', '橙菱形', 'orange diamond'),
      EmojiEntry('🔷', '蓝菱形', 'blue diamond'),
      EmojiEntry('⬆️', '上箭头', 'arrow up'),
      EmojiEntry('⬇️', '下箭头', 'arrow down'),
      EmojiEntry('⬅️', '左箭头', 'arrow left'),
      EmojiEntry('➡️', '右箭头', 'arrow right'),
      EmojiEntry('🔄', '刷新', 'refresh'),
      EmojiEntry('▶️', '播放', 'play'),
      EmojiEntry('⏸️', '暂停', 'pause'),
      EmojiEntry('❤️', '红心', 'heart love red'),
      EmojiEntry('🧡', '橙心', 'orange heart'),
      EmojiEntry('💛', '黄心', 'yellow heart'),
      EmojiEntry('💚', '绿心', 'green heart'),
      EmojiEntry('💙', '蓝心', 'blue heart'),
      EmojiEntry('💜', '紫心', 'purple heart'),
      EmojiEntry('🖤', '黑心', 'black heart'),
      EmojiEntry('🤍', '白心', 'white heart'),
      EmojiEntry('💔', '心碎', 'broken heart'),
      EmojiEntry('💕', '两心', 'two hearts'),
      EmojiEntry('💖', '闪心', 'sparkling heart'),
    ]),
  ];

  @override
  State<EmojiPickerPanel> createState() => _EmojiPickerPanelState();
}

class _EmojiPickerPanelState extends State<EmojiPickerPanel> {
  final TextEditingController _search = TextEditingController();
  int _category = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 当前可见表情：有搜索词 ⇒ 跨分类过滤；否则取选中分类。
  List<EmojiEntry> get _visible {
    final String q = _search.text.trim();
    if (q.isEmpty) return EmojiPickerPanel.categories[_category].entries;
    return <EmojiEntry>[
      for (final EmojiCategory c in EmojiPickerPanel.categories)
        for (final EmojiEntry e in c.entries)
          if (e.matches(q)) e,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool searching = _search.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(Tokens.spaceMd),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _searchField(theme),
          const SizedBox(height: Tokens.spaceSm),
          // 搜索时分类 Tab 隐藏（结果已跨分类，Tab 不再生效）。
          if (!searching) ...<Widget>[
            _categoryTabs(),
            const SizedBox(height: Tokens.spaceSm),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 270),
            child: SingleChildScrollView(child: _grid(theme)),
          ),
        ],
      ),
    );
  }

  Widget _searchField(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    return TextField(
      controller: _search,
      onChanged: (_) => setState(() {}),
      style: theme.textTheme.bodySmall,
      cursorColor: scheme.primary,
      textAlignVertical: TextAlignVertical.center,
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索表情',
        hintStyle: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        filled: false,
        prefixIcon: const tabler.Search(
          height: Tokens.iconXs,
          width: Tokens.iconXs,
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 28),
        contentPadding: const EdgeInsets.symmetric(vertical: Tokens.spaceXs),
        border: _searchBorder(scheme.outlineVariant),
        enabledBorder: _searchBorder(scheme.outlineVariant),
        focusedBorder: _searchBorder(scheme.primary),
        errorBorder: _searchBorder(scheme.outlineVariant),
        disabledBorder: _searchBorder(scheme.outlineVariant),
        focusedErrorBorder: _searchBorder(scheme.primary),
      ),
    );
  }

  OutlineInputBorder _searchBorder(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(Tokens.radiusSm),
    borderSide: BorderSide(color: color),
  );

  Widget _categoryTabs() {
    return Wrap(
      spacing: Tokens.spaceXs,
      runSpacing: Tokens.spaceXs,
      children: <Widget>[
        for (int i = 0; i < EmojiPickerPanel.categories.length; i++)
          _CategoryChip(
            emoji: EmojiPickerPanel.categories[i].icon,
            label: EmojiPickerPanel.categories[i].label,
            selected: i == _category,
            onTap: () => setState(() => _category = i),
          ),
      ],
    );
  }

  Widget _grid(ThemeData theme) {
    final List<EmojiEntry> entries = _visible;
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Tokens.spaceLg),
        child: Text(
          '没有匹配的表情',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Wrap(
      spacing: Tokens.spaceXs,
      runSpacing: Tokens.spaceXs,
      children: <Widget>[
        for (final EmojiEntry e in entries)
          _EmojiCell(emoji: e.char, onPick: widget.onPick),
      ],
    );
  }
}

/// 分类 Tab 小格：hover 铺 [AppTheme.hoverOverlay]、选中铺 [AppTheme.navSelectedTint]。
class _CategoryChip extends StatefulWidget {
  const _CategoryChip({
    required this.emoji,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_CategoryChip> createState() => _CategoryChipState();
}

class _CategoryChipState extends State<_CategoryChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          selected: widget.selected,
          label: widget.label,
          child: Tooltip(
            message: widget.label,
            child: Container(
              width: _cellSize,
              height: _cellSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: widget.selected
                    ? AppTheme.navSelectedTint(theme.colorScheme.onSurface)
                    : _hover
                    ? AppTheme.hoverOverlay(b)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(Tokens.radiusXxs),
              ),
              child: Text(
                widget.emoji,
                style: const TextStyle(fontSize: _emojiFont),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单枚表情格：hover 铺 [AppTheme.hoverOverlay]（热区高亮，不是抬一层）、
/// 4px 硬边、无涟漪 / 无 M3 状态层（PC 观感）。
class _EmojiCell extends StatefulWidget {
  const _EmojiCell({required this.emoji, required this.onPick});

  final String emoji;
  final ValueChanged<String> onPick;

  @override
  State<_EmojiCell> createState() => _EmojiCellState();
}

class _EmojiCellState extends State<_EmojiCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => widget.onPick(widget.emoji),
        child: Semantics(
          button: true,
          label: widget.emoji,
          child: Container(
            width: _cellSize,
            height: _cellSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover
                  ? AppTheme.hoverOverlay(theme.brightness)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Tokens.radiusXxs),
            ),
            child: Text(
              widget.emoji,
              style: const TextStyle(fontSize: _emojiFont),
            ),
          ),
        ),
      ),
    );
  }
}
