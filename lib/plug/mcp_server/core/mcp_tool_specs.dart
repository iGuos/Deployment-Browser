/// MCP 工具定义（名称 + 描述 + JSON Schema 入参）。
class McpToolSpec {
  const McpToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}

// 工具名常量，core 服务器与 application dispatcher 共用，避免拼写漂移。
const String kToolListAccounts = 'list_accounts';
const String kToolListProjects = 'list_projects';
const String kToolGetProjectParameters = 'get_project_parameters';
const String kToolTriggerBuild = 'trigger_build';
const String kToolGetBuildStatus = 'get_build_status';
const String kToolGetReleaseHistory = 'get_release_history';
const String kToolStopBuild = 'stop_build';

/// `trigger_build` 默认最多等多少秒，直到 Jenkins 给本次触发分配构建号。
/// 常见 Jenkins quiet period 为 5 秒，再留出排队 / 拉起执行器的余量。
const int kMcpDefaultTriggerWaitSeconds = 20;

Map<String, dynamic> _obj(
  Map<String, dynamic> properties, {
  List<String> required = const [],
}) =>
    {
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
      'additionalProperties': false,
    };

const _accountIdProp = {
  'type': 'string',
  'description': '账号 ID（来自 list_accounts 返回的 id）',
};
const _projectProp = {
  'type': 'string',
  'description': '项目的 Jenkins fullName（来自 list_projects 返回的 fullName），如 backend/order-service',
};

/// 对外暴露的 7 个工具。
final List<McpToolSpec> kMcpToolSpecs = [
  McpToolSpec(
    name: kToolListAccounts,
    description: '查询当前已配置且该令牌可访问的所有 Jenkins 账号，返回账号 ID 与名称。',
    inputSchema: _obj(const {}),
  ),
  McpToolSpec(
    name: kToolListProjects,
    description: '根据账号 ID 查询该账号下所有可发版的项目（含多分支流水线）。',
    inputSchema: _obj(const {'accountId': _accountIdProp}, required: ['accountId']),
  ),
  McpToolSpec(
    name: kToolGetProjectParameters,
    description: '根据账号 ID 与项目 fullName 查询触发该项目发版所需的构建参数定义（名称、类型、默认值、可选项）。',
    inputSchema: _obj(
      const {'accountId': _accountIdProp, 'projectFullName': _projectProp},
      required: ['accountId', 'projectFullName'],
    ),
  ),
  McpToolSpec(
    name: kToolTriggerBuild,
    description: '根据账号 ID、项目 fullName 与参数触发一次发版构建。'
        '返回本次发版的 triggerId（每次调用都不同、永不为 null，是关联本次发版的唯一键）、'
        'queueId（Jenkins 队列项 id，部分 Jenkins / 反向代理拿不到时为 null）与 buildNumber（发版号）；'
        '默认最多等待 $kMcpDefaultTriggerWaitSeconds 秒直到 Jenkins 分配 buildNumber，'
        '仍未分配时 buildNumber 为 null 且 queued=true，可用 get_build_status 传 triggerId 换回发版号。'
        '同一项目连续多次发版时，请为每次调用单独保存 triggerId 并用它关联，不要按时间或项目名猜测。',
    inputSchema: _obj(
      {
        'accountId': _accountIdProp,
        'projectFullName': _projectProp,
        'parameters': {
          'type': 'object',
          'description': '构建参数键值对（值统一按字符串处理）；未提供的参数会用项目默认值补齐。',
          'additionalProperties': {'type': 'string'},
        },
        'waitForBuildNumberSeconds': {
          'type': 'integer',
          'description': '等待 Jenkins 分配发版号的最长秒数，0–180，默认 $kMcpDefaultTriggerWaitSeconds；'
              '传 0 表示立刻返回（可能只有 queueId）。',
        },
      },
      required: ['accountId', 'projectFullName'],
    ),
  ),
  McpToolSpec(
    name: kToolGetBuildStatus,
    description: '查询发版进度（构建状态、流水线阶段）及控制台日志。'
        '定位方式优先级：buildNumber > triggerId（trigger_build 返回的唯一键，会自动换回发版号）'
        '> queueId > 最近一次构建。'
        '只传 triggerId 即可——账号与项目会从该次触发的记录里取，accountId 与 '
        'projectFullName 可省略；不传 triggerId 时这两个必填。'
        '程序化轮询请传 triggerId（或已知的 buildNumber），否则同一项目多次发版时可能读到别人的构建。',
    inputSchema: _obj(
      {
        'accountId': _accountIdProp,
        'projectFullName': _projectProp,
        'buildNumber': {
          'type': 'integer',
          'description': '构建号（发版号）；与 triggerId / queueId 都省略时使用最近一次构建。',
        },
        'triggerId': {
          'type': 'string',
          'description': 'trigger_build 返回的 triggerId；用于把「某一次触发」精确换回其发版号。'
              '传了它就可以省略 accountId 与 projectFullName。'
              '若该次发版仍在排队，返回 found=false 且 queued=true。',
        },
        'queueId': {
          'type': 'integer',
          'description': 'Jenkins 队列项 id（trigger_build 返回，可能为 null）；'
              '仅在没有 triggerId 时使用，作用同 triggerId。',
        },
        'logStart': {
          'type': 'integer',
          'description': '增量日志起始字节偏移（默认 0）；配合返回的 nextStart 可分段拉取。',
        },
        'includeLog': {
          'type': 'boolean',
          'description': '是否返回控制台日志，默认 true。',
        },
      },
      // 不设 required：传 triggerId 时账号与项目从台账里取。
    ),
  ),
  McpToolSpec(
    name: kToolStopBuild,
    description: '终止一次发版：已开始的构建走 Jenkins 的 stop（必要时升级 term），'
        '仍在队列里、还没分配发版号的则取消排队项。'
        '定位方式优先级：buildNumber > triggerId > queueId > 最近一次构建（需显式 latest=true）。'
        '只传 triggerId 即可——账号与项目会从该次触发的记录里取。'
        '返回 action 说明实际做了什么：stopped（终止了运行中的构建）/ '
        'cancelledInQueue（取消了排队项）/ noop（已经结束，无需终止）。',
    inputSchema: _obj(
      {
        'accountId': _accountIdProp,
        'projectFullName': _projectProp,
        'triggerId': {
          'type': 'string',
          'description': 'trigger_build 返回的 triggerId；终止该次发版。'
              '传了它就可以省略 accountId 与 projectFullName。',
        },
        'buildNumber': {
          'type': 'integer',
          'description': '要终止的构建号（发版号）。',
        },
        'queueId': {
          'type': 'integer',
          'description': 'Jenkins 队列项 id；构建号还没分配时用它取消排队。',
        },
        'latest': {
          'type': 'boolean',
          'description': '未给出任何定位参数时，是否终止该项目最近一次构建，默认 false。'
              '终止是破坏性操作，必须显式要求才会作用于「最近一次」。',
        },
      },
      // 不设 required：传 triggerId 时账号与项目从台账里取。
    ),
  ),
  McpToolSpec(
    name: kToolGetReleaseHistory,
    description: '根据账号 ID 与项目 fullName 查询历史发版记录'
        '（构建号、queueId、结果、触发人、参数快照、Git 提交）。'
        '每条还会带上 triggerId：该构建由本接口哪一次 trigger_build 触发，'
        '不是经本接口触发（界面发版 / 在 Jenkins 上手动发 / 服务重启前）则为 null，'
        '可用它把历史记录与自己发过的版一一对上。',
    inputSchema: _obj(
      {
        'accountId': _accountIdProp,
        'projectFullName': _projectProp,
        'count': {
          'type': 'integer',
          'description': '返回的最大记录数，默认 20。',
        },
      },
      required: ['accountId', 'projectFullName'],
    ),
  ),
];
