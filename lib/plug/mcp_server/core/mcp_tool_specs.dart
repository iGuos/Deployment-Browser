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

/// 对外暴露的 6 个工具。
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
        '返回本次发版的 queueId（触发即确定，是关联本次发版的唯一键）与 buildNumber（发版号）；'
        '默认最多等待 $kMcpDefaultTriggerWaitSeconds 秒直到 Jenkins 分配 buildNumber，'
        '仍未分配时 buildNumber 为 null 且 queued=true，可用 get_build_status 传 queueId 换回发版号。'
        '同一项目连续多次发版时，请始终用 queueId / buildNumber 关联，不要按时间猜测。',
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
    description: '根据账号 ID 与项目 fullName 查询发版进度（构建状态、流水线阶段）及控制台日志。'
        '定位方式优先级：buildNumber > queueId（trigger_build 返回的关联键，会自动换回发版号）> 最近一次构建。'
        '程序化轮询请传 queueId 或 buildNumber，否则并发发版时可能读到别人的构建。',
    inputSchema: _obj(
      {
        'accountId': _accountIdProp,
        'projectFullName': _projectProp,
        'buildNumber': {
          'type': 'integer',
          'description': '构建号（发版号）；与 queueId 都省略时使用最近一次构建。',
        },
        'queueId': {
          'type': 'integer',
          'description': 'trigger_build 返回的 queueId；用于把「某一次触发」精确换回其发版号。'
              '若该次发版仍在排队，返回 found=false 且 queued=true。',
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
      required: ['accountId', 'projectFullName'],
    ),
  ),
  McpToolSpec(
    name: kToolGetReleaseHistory,
    description: '根据账号 ID 与项目 fullName 查询历史发版记录（构建号、queueId、结果、触发人、参数快照、Git 提交）。',
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
