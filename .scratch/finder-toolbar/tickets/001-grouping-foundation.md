# 001 分组地基：FileItem 属性扩展 + GroupingService 纯函数 + 自检

**Blocked by**: 无

## 目标
给定一组 FileItem 和任意分组维度，`GroupingService` 能输出正确的有序分组（组名、组间顺序、成员归属），可用一个断言式自检独立验证。

## 涉及层
- [ ] 数据层：`FileItem` 补资源属性——创建日期（`creationDateKey`）、添加日期（`addedToDirectoryDateKey`）、上次打开日期（`contentAccessDateKey`，缺失回退不抛错）、标签名（`tagNamesKey`）；沿用现有 `resourceValues` 懒取模式，全部 Optional
- [ ] 逻辑层：新 `GroupDimension` 枚举（10 case：无/名称/种类/应用程序/上次打开日期/添加日期/修改日期/创建日期/大小/标签）+ 新 `GroupingService.group(files:dimension:sortOption:sortDirection:)` 纯函数，输出 `[(组名, [FileItem])]`：
  - 名称：首字符归组，字母→字母，非字母→「#」，组间字母序
  - 种类：文件夹/应用程序/图像/文稿/归档 等大类，组间按组名
  - 应用程序：「应用程序」「其他」两组
  - 四种日期：今天/昨天/前 7 天/前 30 天/今年/更早/无日期，组间从新到旧
  - 大小：文件夹/1 GB 以上/100–1000 MB/10–100 MB/1–10 MB/100 KB–1 MB/10–100 KB/小于 10 KB/未知大小，组间从大到小
  - 标签：按第一个标签归组（按 `FinderTag.all` 顺序），无标签归「无标签」
  - 「无」：返回单组平铺
  - 组内排序：按入参 SortOption/SortDirection（与现有列表排序同语义）
- [ ] UI层：不动
- [ ] 测试：断言式自检（无框架，可执行的单文件 check）：构造临时文件 + 预置资源属性，断言每个维度的组名序列、边界桶（如 99KB/100KB、29/30/31 天、今天零点）、组内排序方向、空列表返回空

## 验收标准
- 自检可运行且通过（swift 命令一行可执行）
- 每个 10 维度至少覆盖 1 个正例 + 边界桶各 1 例
- `swift build` 通过，不引入新依赖
