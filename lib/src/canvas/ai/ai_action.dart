import 'dart:convert';
import 'dart:ui' show Offset, Rect;

import '../kernel/canvas_edge.dart' show EdgeEndpointShape;
import '../kernel/canvas_item.dart' show CanvasShapeKind;

/// A 阶段（结构轨）的 **typed action**：模型唯一被允许用来改画布的词汇表。
///
/// ## 为什么"写"只能是结构化的
/// 像素轨（img2img）能给"感觉"，但**改不了一个字的文本、挪不了一个卡片 10px**。
/// 所有落在文档上的改动都必须以"元素 id + 语义"表达，也就是这套动作。
/// 详见 `docs/ai_canvas_research.md` §4.2。
///
/// ## 坐标一律**视口归一化**
/// 所有 `rect` / `at` 都是相对**当前视口世界矩形**的 `[0,1]` 值，由确定性代码换算成
/// 世界坐标（见 [NormRect.toWorld]）。这是本模块最重要的决定：LLM 空间能力很弱，
/// 让它直吐绝对坐标必错（Set-of-Mark / OmniParser 两篇论文的出发点）。归一化把
/// "猜数值"换成"指相对位置"，还天然保证结果落在用户看得见的地方。
/// 对应物是 tldraw agent 的坐标空间转换（`removeOffsetFromShapePartial`）。
///
/// ## 解析原则：**不认识就丢，绝不抛**
/// 模型输出的每个字节都不可信（未知 op、错类型、缺字段都会出现）。[tryParse] 一律
/// 返回 `null` 交给调用方丢弃——让一个坏动作炸掉整批是错的。
///
/// 各类的 `op` 是 `static const`（供 schema 与解析共用）；不设同名实例成员，
/// 因为 Dart 禁止同一个类里静态成员与实例成员重名。
sealed class AiAction {
  const AiAction();

  /// 从模型回复的**原文**里解析出动作列表（容错，**绝不抛**）。
  ///
  /// 三步容错缺一不可：
  /// ① 剥掉 markdown 围栏与前后闲话（见 `extractJsonObject`）—— JSON Schema 只
  ///    约束输出形状，管不住模型"顺便说一句"；
  /// ② 解 JSON；
  /// ③ 逐条 [tryParse]，坏的那条**丢弃**而不是让整批失败。
  ///
  /// 返回 `null` 与返回空列表是**两件事**：
  /// - `null` = 整体不可用（不是 JSON / 没有 `actions` 数组）⇒ 调用方应重试一次；
  /// - `[]` = 解析成功但一条都没有 ⇒ 模型没想改，重试也没用，直接告诉用户。
  static List<AiAction>? parseReply(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(extractJsonObject(raw));
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final Object? list = decoded['actions'];
    if (list is! List) return null;
    return <AiAction>[
      for (final Object? item in list)
        if (tryParse(item) case final AiAction action) action,
    ];
  }

  /// 按 `op` 分发；任何不合规都返回 `null`。
  static AiAction? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> j = raw.cast<String, Object?>();
    return switch (j['op']) {
      ReferenceBlockAction.op => ReferenceBlockAction._parse(j),
      AddShapeAction.op => AddShapeAction._parse(j),
      AddMindMapAction.op => AddMindMapAction._parse(j),
      MoveItemAction.op => MoveItemAction._parse(j),
      SetTextAction.op => SetTextAction._parse(j),
      ConnectAction.op => ConnectAction._parse(j),
      GroupAction.op => GroupAction._parse(j),
      UngroupAction.op => UngroupAction._parse(j),
      DeleteAction.op => DeleteAction._parse(j),
      _ => null,
    };
  }
}

/// 视口归一化的点：`[x, y] ∈ [0,1]²`。
class NormPoint {
  const NormPoint(this.x, this.y);

  final double x;
  final double y;

  Offset toWorld(Rect viewportWorld) => Offset(
    viewportWorld.left + x * viewportWorld.width,
    viewportWorld.top + y * viewportWorld.height,
  );

  static NormPoint? tryParse(Object? raw) {
    if (raw is! List || raw.length < 2) return null;
    final Object? x = raw[0];
    final Object? y = raw[1];
    if (x is! num || y is! num) return null;
    return NormPoint(x.toDouble(), y.toDouble());
  }
}

/// 视口归一化的矩形：`[left, top, right, bottom] ∈ [0,1]⁴`。
///
/// 用 `[l,t,r,b]` 而非 `[x,y,w,h]`：与 item 的 `rect` 序列化同口径
/// （见各 `CanvasItem.toJson`），少一次心智换算就少一类模型错误。
class NormRect {
  const NormRect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  static NormRect ofLTRB(
    double left,
    double top,
    double right,
    double bottom,
  ) => NormRect(left, top, right, bottom);

  Rect toWorld(Rect viewportWorld) => Rect.fromLTRB(
    viewportWorld.left + left * viewportWorld.width,
    viewportWorld.top + top * viewportWorld.height,
    viewportWorld.left + right * viewportWorld.width,
    viewportWorld.top + bottom * viewportWorld.height,
  );

  static NormRect? tryParse(Object? raw) {
    if (raw is! List || raw.length < 4) return null;
    final Object? l = raw[0];
    final Object? t = raw[1];
    final Object? r = raw[2];
    final Object? b = raw[3];
    if (l is! num || t is! num || r is! num || b is! num) return null;
    return NormRect(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble());
  }
}

/// 把**已存在的块**引用到画布上（做成一张卡片）。
///
/// A 阶段的主力动作：不新建 `blocks` 行（数据层尚无该 API），只把库里已有的块摆到
/// 画布上——对应 tldraw 的 "Mermaid → shape"，只是我们的 DSL 是笔记库本身。
class ReferenceBlockAction extends AiAction {
  const ReferenceBlockAction({required this.blockId, required this.at});

  static const String op = 'reference_block';

  final String blockId;

  /// 卡片**中心**的归一化位置。
  final NormPoint at;

  static ReferenceBlockAction? _parse(Map<String, Object?> j) {
    final Object? blockId = j['blockId'];
    final NormPoint? at = NormPoint.tryParse(j['at']);
    if (blockId is! String || blockId.isEmpty || at == null) return null;
    return ReferenceBlockAction(blockId: blockId, at: at);
  }
}

/// 加一个矢量形状。
class AddShapeAction extends AiAction {
  const AddShapeAction({required this.kind, required this.rect});

  static const String op = 'add_shape';

  final CanvasShapeKind kind;
  final NormRect rect;

  static AddShapeAction? _parse(Map<String, Object?> j) {
    final NormRect? rect = NormRect.tryParse(j['rect']);
    if (rect == null) return null;
    // kind 缺失/不认识 ⇒ 退回矩形（比丢整条动作友好，矩形也是默认工具）。
    final Object? rawKind = j['kind'];
    final CanvasShapeKind kind = rawKind is String
        ? CanvasShapeKind.values.firstWhere(
            (CanvasShapeKind k) => k.name == rawKind,
            orElse: () => CanvasShapeKind.rectangle,
          )
        : CanvasShapeKind.rectangle;
    return AddShapeAction(kind: kind, rect: rect);
  }
}

/// 新建一张思维导图。
class AddMindMapAction extends AiAction {
  const AddMindMapAction({
    required this.rect,
    required this.root,
    this.children = const <String>[],
  });

  static const String op = 'add_mindmap';

  final NormRect rect;

  /// 中心主题文本。
  final String root;

  /// 一级分支文本（A 阶段不做深层嵌套）。
  final List<String> children;

  static AddMindMapAction? _parse(Map<String, Object?> j) {
    final NormRect? rect = NormRect.tryParse(j['rect']);
    final Object? root = j['root'];
    if (rect == null || root is! String || root.isEmpty) return null;
    return AddMindMapAction(
      rect: rect,
      root: root,
      children: _stringList(j['children']),
    );
  }
}

/// 移动一个 item：`at` 是**新的中心**归一化位置。
///
/// 用中心而非左上角：模型更容易判断"放到这块区域中间"，且中心不动就不会把元素
/// 推到视口外（净化层还会再钳一次）。
class MoveItemAction extends AiAction {
  const MoveItemAction({required this.id, required this.at});

  static const String op = 'move_item';

  final String id;
  final NormPoint at;

  static MoveItemAction? _parse(Map<String, Object?> j) {
    final Object? id = j['id'];
    final NormPoint? at = NormPoint.tryParse(j['at']);
    if (id is! String || id.isEmpty || at == null) return null;
    return MoveItemAction(id: id, at: at);
  }
}

/// 改写一张**卡片**的文本（落盘时由存储层写回 `blocks`，真身在块里）。
class SetTextAction extends AiAction {
  const SetTextAction({required this.id, required this.text});

  static const String op = 'set_text';

  final String id;
  final String text;

  static SetTextAction? _parse(Map<String, Object?> j) {
    final Object? id = j['id'];
    final Object? text = j['text'];
    if (id is! String || id.isEmpty || text is! String) return null;
    return SetTextAction(id: id, text: text);
  }
}

/// 连一条线。端点用 **blockId**（与存储外键、`Document.edgesIn` 同口径）。
class ConnectAction extends AiAction {
  const ConnectAction({
    required this.fromBlockId,
    required this.toBlockId,
    this.endShape = EdgeEndpointShape.arrow,
  });

  static const String op = 'connect';

  final String fromBlockId;
  final String toBlockId;
  final EdgeEndpointShape endShape;

  static ConnectAction? _parse(Map<String, Object?> j) {
    final Object? from = j['from'];
    final Object? to = j['to'];
    if (from is! String || from.isEmpty || to is! String || to.isEmpty) {
      return null;
    }
    return ConnectAction(
      fromBlockId: from,
      toBlockId: to,
      endShape: EdgeEndpointShape.parse(
        j['endShape'],
        defaultShape: EdgeEndpointShape.arrow,
      ),
    );
  }
}

/// 把若干 item 装进一个分组框。
class GroupAction extends AiAction {
  const GroupAction({required this.ids, this.label = ''});

  static const String op = 'group';

  final List<String> ids;
  final String label;

  static GroupAction? _parse(Map<String, Object?> j) {
    final List<String> ids = _stringList(j['ids']);
    if (ids.isEmpty) return null;
    final Object? label = j['label'];
    return GroupAction(ids: ids, label: label is String ? label : '');
  }
}

/// 解散分组框（按**框**的 item id 指定）。
class UngroupAction extends AiAction {
  const UngroupAction({required this.ids});

  static const String op = 'ungroup';

  final List<String> ids;

  static UngroupAction? _parse(Map<String, Object?> j) {
    final List<String> ids = _stringList(j['ids']);
    if (ids.isEmpty) return null;
    return UngroupAction(ids: ids);
  }
}

/// 删除若干 item。
class DeleteAction extends AiAction {
  const DeleteAction({required this.ids});

  static const String op = 'delete';

  final List<String> ids;

  static DeleteAction? _parse(Map<String, Object?> j) {
    final List<String> ids = _stringList(j['ids']);
    if (ids.isEmpty) return null;
    return DeleteAction(ids: ids);
  }
}

/// 从模型回复里**抠出**一个 JSON 对象文本。
///
/// ## 为什么需要它（明明已经传了 `format`）
/// JSON Schema 只约束**输出形状**，不保证模型不画蛇添足。实测常见三种脏输出：
/// 套一层 ```json 围栏、前后加一句"好的，这是结果："、以及两者都占。
/// 这些都属于"答对了但包装不对"，为此整批失败太亏。
///
/// 策略：剥掉围栏后，**取第一个 `{` 到最后一个 `}`**。保守（不会把两段 JSON 拼
/// 起来），失败时原样返回，交给 `jsonDecode` 去报错。
String extractJsonObject(String raw) {
  String s = raw.trim();
  if (s.startsWith('```')) {
    final int firstNewline = s.indexOf('\n');
    if (firstNewline >= 0) s = s.substring(firstNewline + 1);
    final int fence = s.lastIndexOf('```');
    if (fence >= 0) s = s.substring(0, fence);
    s = s.trim();
  }
  final int start = s.indexOf('{');
  final int end = s.lastIndexOf('}');
  if (start >= 0 && end > start) return s.substring(start, end + 1);
  return s;
}

/// 取一串**非空字符串**；任何元素不合规就整条判空（宁可丢，不可半信）。
List<String> _stringList(Object? raw) {
  if (raw is! List) return const <String>[];
  final List<String> out = <String>[];
  for (final Object? v in raw) {
    if (v is! String || v.isEmpty) return const <String>[];
    out.add(v);
  }
  return out;
}

/// 所有合法 `op` 的字面值（给提示词与 schema 用）。
///
/// `group` / `ungroup` 于 **A6** 归队：那之前 `CanvasItem.groupId` 是 `final`、
/// 文档层没有成员关系 API，属于**能力缺口**（不是策略），所以刻意摘出词汇表，
/// 免得模型把输出预算浪费在必被丢弃的动作上。现在
/// `CanvasDocument.setItemGroupIds` 补上了这条路。
const List<String> kAiActionOps = <String>[
  ReferenceBlockAction.op,
  AddShapeAction.op,
  AddMindMapAction.op,
  MoveItemAction.op,
  SetTextAction.op,
  ConnectAction.op,
  GroupAction.op,
  UngroupAction.op,
  DeleteAction.op,
];

/// 传给 Ollama `format` 字段的 **JSON Schema**（已核实 `/api/chat` 接受 schema
/// 对象，见 `docs/ai_structure_track_plan.md` §2.1）。
///
/// ## 为什么与解析器放在同一个文件
/// schema 与各 `_parse` 是同一份契约的两个面，**必须同步演进**。分开放迟早漂移，
/// 而漂移的症状是"模型照着 schema 输出、解析器却认不出"——最难查的一类 bug。
///
/// ## 为什么只用 enum 钉住 `op`、其余字段不写 `required`
/// 严格写法要按 `op` 分支 `oneOf`，而本地小模型对 `oneOf` 普遍处理不稳。折中：
/// 只用 enum 钉住 `op`（最关键的一位），字段完备性交给**净化层**兜——那是确定性
/// 的，比让模型再猜一层可靠。
const Map<String, Object?> kAiActionSchema = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{
    'actions': <String, Object?>{
      'type': 'array',
      'maxItems': 50,
      'items': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'op': <String, Object?>{'type': 'string', 'enum': kAiActionOps},
          'blockId': <String, Object?>{'type': 'string'},
          'id': <String, Object?>{'type': 'string'},
          'from': <String, Object?>{'type': 'string'},
          'to': <String, Object?>{'type': 'string'},
          'text': <String, Object?>{'type': 'string'},
          'label': <String, Object?>{'type': 'string'},
          'root': <String, Object?>{'type': 'string'},
          'kind': <String, Object?>{
            'type': 'string',
            'enum': <String>['rectangle', 'ellipse'],
          },
          'endShape': <String, Object?>{
            'type': 'string',
            'enum': <String>['none', 'arrow', 'dot', 'diamond'],
          },
          'at': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'number'},
          },
          'rect': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'number'},
          },
          'ids': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
          },
          'children': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
          },
        },
        'required': <String>['op'],
      },
    },
  },
  'required': <String>['actions'],
};
