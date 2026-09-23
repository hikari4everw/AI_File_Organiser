# 验收清单与评测工具

计划要求固定至少 **50 项独立验收样本**（建议 30 项类别明确的同人志 + 20 项易混淆或其他类型），
样本不得参与学习和调参。本目录提供清单格式与评测工具；**真实样本仍需人工标注后放入清单**。

## 现状（重要）

- 仓库内的 `manifest.json` 只有 `sample-` 前缀的示例条目，用于演示字段和自检。
- 评测工具在清单只含示例条目时以退出码 `3` 结束，**不会报告通过**。
- 因此“明确同人志首选分类正确率 ≥95%”“可批量接受 ≥80%”“默认纳入方案不得错分”
  这三条目前仍是**未验证**状态，直到真实样本补齐并跑出报告。

## 清单格式

```json
{
  "version": 1,
  "description": "说明",
  "cases": [
    {
      "id": "holdout-001",
      "name": "[おじたん屋さん (まめおじたん)] 愛娘性活 [中国翻訳] [DL版]",
      "group": "definite-doujin",
      "split": "holdout",
      "expectedCategory": "bunga",
      "expectedCreator": "bunga/[おじたん屋さん] まめおじたん",
      "relativePath": "bunga/[おじたん屋さん] まめおじたん/愛娘性活"
    }
  ]
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | 是 | 唯一标识。示例条目必须以 `sample-` 开头。 |
| `name` | 是 | 送进分类器的项目名称。 |
| `group` | 是 | `definite-doujin`（类别明确）或 `confusable`（易混淆/其他）。 |
| `split` | 是 | `dev`（允许调参）或 `holdout`（只用于判定）。 |
| `expectedCategory` | 明确同人志必填 | 期望的首选分类目录相对路径。 |
| `expectedCreator` | 否 | 期望的作者归档目录，仅用于**另行审核**作者路由，不计入分类门槛。 |
| `relativePath` | 否 | 资料库内真实路径，用于提供正文/OCR/画面证据；留空则只测名称与结构。 |

`split` 的纪律：调参只能看 `dev` 的报告；`holdout` 一旦用于调参就不再是留出集，必须重新标注新样本替换。

## 运行

```bash
AI_FILE_ORGANIZER_ACCEPTANCE_LIBRARY=/path/to/library \
  swift run --disable-sandbox AIFileOrganizerAcceptance Evaluation/acceptance/manifest.json
```

可选：设置 `AI_FILE_ORGANIZER_TEST_MODEL=/path/to/MobileCLIP-BLT.mlmodelc`，
工具会**追加**一档“有图像模型”的报告；未设置时只报告“无图像模型”。

退出码：

| 码 | 含义 |
|---|---|
| 0 | 全部门槛通过 |
| 1 | 有门槛未通过（报告里逐条列出） |
| 2 | 用法或环境问题（缺资料库根目录、清单解析失败等） |
| 3 | 清单只有示例条目，没有真实验收样本 |

## 门槛（只作用于 `holdout`）

- 留出集样本数 ≥ 50；其中 `definite-doujin` ≥ 30。
- `definite-doujin` 首选分类正确率 ≥ 95%（30 项时至少 29 项）。
- `definite-doujin` 进入可批量接受建议组 ≥ 80%（30 项时至少 24 项）。
- 留出集中“默认纳入方案却分错”的项必须为 0。

样本数不足时对应门槛直接判为未通过，避免用少量样本“凑”出高准确率。
