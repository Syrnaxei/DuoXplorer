# 004 分享按钮：NSSharingServicePicker

**Blocked by**: 无

## 目标
选中 ≥1 个对象时点分享按钮弹出系统分享面板，可隔空投送/邮件/信息分享全部选中文件。

## 涉及层
- [ ] 数据层：无新增（读现有 `selectedURLs`）
- [ ] 逻辑层：无（纯原生接口）
- [ ] UI层：
  - 工具栏分享按钮（SF Symbol `square.and.arrow.up`），无选中时 disabled
  - 点击构造 `NSSharingServicePicker(items: 选中文件 URL 数组)` 并 `show(relativeTo:)` 于按钮
- [ ] 测试：手动验证清单（置灰时机、多选分享、取消面板无副作用）

## 验收标准
- 未选中任何对象：按钮置灰
- 选中 2 个文件点按钮：分享面板出现，隔空投送/邮件可见 2 个文件
- 关闭面板不改变选中与列表状态
