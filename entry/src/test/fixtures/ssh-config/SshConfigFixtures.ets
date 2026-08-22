export const CONFIG_ROUND_TRIP_LF: string =
  '# migrated workstation config\n' +
  '\n' +
  'Host prod production # repeated concrete patterns\n' +
  '  HostName prod.example.test\n' +
  '  User deploy\n' +
  '  Port 2222\n' +
  '  IdentityFile ~/.ssh/id_work\n' +
  '  ProxyJump jump\n' +
  '  ConnectTimeout 12\n' +
  '  ServerAliveInterval 30\n' +
  '  ServerAliveCountMax 3\n' +
  '\n' +
  'Host jump\n' +
  '  HostName jump.example.test\n' +
  '  User gateway\n' +
  '\n' +
  'Host *.lab !blocked.lab\n' +
  '  User operator\n' +
  '\n' +
  'Host prod\n' +
  '  Port 2200\n'

export const CONFIG_ROUND_TRIP_CRLF: string =
  '# CRLF fixture\r\n' +
  'Host crlf\r\n' +
  '\tHostName crlf.example.test\r\n' +
  '\tUser deploy\r\n'

export const CONFIG_UNKNOWN_DIRECTIVE: string =
  'Host guarded\n' +
  '  HostName guarded.example.test\n' +
  '  User deploy\n' +
  '  StrictHostKeyChecking yes\n'

export const CONFIG_INCLUDE: string =
  'Include ~/.ssh/conf.d/*.conf\nHost included\n  User deploy\n'

export const CONFIG_MATCH: string =
  'Host matched\n  User deploy\nMatch user deploy\n  Port 2222\n'

export const CONFIG_TOKEN_EXPANSION: string =
  'Host token\n  HostName %h.internal.example.test\n  User deploy\n'
