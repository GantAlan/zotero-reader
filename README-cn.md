# zotero-reader 中文说明

`zotero-reader` 是一个面向 Windows 的 Codex Skill，用于把 Zotero 文献集合变成可排队处理的论文阅读任务，让 Codex worker 自动生成 Markdown 阅读笔记，并可将笔记导入回 Zotero 子笔记。

## 适用场景

你可以用它来：

- 从 Zotero collection 生成论文阅读队列。
- 批量运行 Codex worker 阅读论文。
- 生成结构化 Markdown 阅读笔记。
- 监控 worker 运行状态。
- 把生成的笔记导入回 Zotero。
- 打包一个可复用的论文阅读自动化项目。

## 安装方式

### 方法一：从 GitHub 克隆

```powershell
cd $env:USERPROFILE\.codex\skills
git clone https://github.com/GantAlan/zotero-reader.git zotero-reader
```

最终目录应该是：

```text
C:\Users\<你的用户名>\.codex\skills\zotero-reader\SKILL.md
```

### 方法二：下载 ZIP

1. 打开仓库：<https://github.com/GantAlan/zotero-reader>
2. 点击 `Code -> Download ZIP`。
3. 解压后，把 `zotero-reader` 文件夹复制到：

```text
C:\Users\<你的用户名>\.codex\skills\
```

## 快速开始

安装后，在 Codex 里说：

```text
使用 zotero-reader，帮我创建一个 Zotero 论文阅读池项目
```

或者手动运行脚本生成项目：

```powershell
cd $env:USERPROFILE\.codex\skills\zotero-reader
.\scripts\scaffold-package.ps1 -Destination "C:\Users\<你的用户名>\Desktop\paper-reading-pool"
```

然后进入生成的项目目录：

```powershell
cd "C:\Users\<你的用户名>\Desktop\paper-reading-pool"
```

## 配置 Zotero 集合

推荐使用脚本设置 Zotero collection，而不是手动改 key：

```powershell
.\scripts\set-zotero-collection.ps1
```

你可以按 Zotero collection 路径填写，例如：

```text
Top Collection -> Child Collection
```

配置文件在：

```text
configs\paper-reading-pool-config.json
```

## 运行 worker

一次性运行：

```powershell
.\scripts\run-once-workers.ps1
```

启动持续 worker：

```powershell
.\scripts\start-paper-reading-pool.ps1
```

查看队列 / 状态：

```powershell
.\scripts\manage-paper-reading-pool.ps1
```

健康检查：

```powershell
.\scripts\health-check.ps1
```

## 导入笔记回 Zotero

导入全部生成笔记：

```powershell
.\scripts\import-zotero-notes-all.ps1
```

每次导入 10 条：

```powershell
.\scripts\import-zotero-notes-batch10.ps1
```

验证导入结果：

```powershell
.\scripts\verify-zotero-note-imports.ps1
```

## 重要目录

```text
configs/                 配置文件
queue/                   任务队列
logs/                    运行日志
study-paper/             生成的阅读笔记
study-paper-template/    阅读笔记模板
scripts/                 自动化脚本
```

## 注意事项

- Zotero Desktop 需要保持打开。
- 不要直接写 Zotero SQLite 数据库。
- 不要上传真实 API Key、`.env`、本地 logs、运行状态文件。
- 首次运行建议只开 1 个 worker，确认稳定后再增加。

## 不要上传这些内容

```text
logs/
state/
.env
*.secret.*
真实 API Key
本地生成的运行队列和笔记，除非你明确想公开
```

## 更多说明

仓库内还包含：

```text
references/README.zh-CN.md
references/workflow.md
references/parameter-guide.md
assets/package-template/docs/
```

如果要做完整自动化项目，请优先阅读中文说明：

```text
references/README.zh-CN.md
```
