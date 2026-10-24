'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require poll';

return view.extend({
	render: function() {
		let m, s, o;

		m = new form.Map('dae-box', _('dae-box'),
			_('dae-box 是融合 eBPF 内核旁路、sing-box 协议核心与 Clash 控制面的下一代透明代理引擎。'));

		s = m.section(form.TypedSection, 'config', _('运行状态与基础设置'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用 dae-box 服务'));
		o.rmempty = false;

		o = s.option(form.Value, 'config_file', _('配置文件路径'));
		o.default = '/etc/dae-box/config.yaml';
		o.rmempty = false;

		o = s.option(form.Value, 'subscription_url', _('订阅链接 (可选)'));
		o.description = _('支持 Clash YAML 或 Base64 订阅链接，启动时自动拉取并解析');
		o.rmempty = true;

		o = s.option(form.Value, 'mixed_port', _('混合监听端口 (Mixed Port)'));
		o.datatype = 'port';
		o.default = '7890';
		o.rmempty = false;

		o = s.option(form.Value, 'api_port', _('Clash REST API 控制端口'));
		o.datatype = 'port';
		o.default = '9090';
		o.rmempty = false;

		o = s.option(form.Value, 'api_secret', _('API 访问密钥 (Secret)'));
		o.password = true;
		o.rmempty = true;

		s = m.section(form.TypedSection, 'config', _('eBPF 内核旁路加速 (dae 特性)'));
		s.anonymous = true;

		o = s.option(form.Flag, 'ebpf_enable', _('启用 eBPF tc/ingress 旁路加速'));
		o.description = _('利用 eBPF 在网络接口层直接旁路放行局域网及直连流量，消除 iptables 开销并实现零拷贝');
		o.default = '1';

		o = s.option(form.DynamicList, 'interfaces', _('监听网卡接口'));
		o.default = ['br-lan'];
		o.description = _('需要挂载 eBPF 过滤探针的局域网桥或物理网卡 (例如 br-lan, eth0)');

		// Web 仪表盘跳转入口
		s = m.section(form.NamedSection, 'config', 'config', _('Web 控制面板'));
		o = s.option(form.Button, 'dashboard', _('打开 Metacubexd 仪表盘'));
		o.inputtitle = _('打开控制面板');
		o.inputstyle = 'apply';
		o.onclick = function() {
			window.open('http://' + window.location.hostname + ':9090/ui', '_blank');
		};

		return m.render();
	}
});
