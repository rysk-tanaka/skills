---
name: design-doc-yaml
description: 設計内容をYAMLに集約し診断レビューを経て肥大化しないMarkdown設計書を作成 (user)
license: MIT
argument-hint: "[topic]"
allowed-tools: Read Bash(uv run *) Write
---

# 設計書作成（YAMLファースト）

設計書を「構造の作成（安価でレビュー可能なYAML）」と「成果物の生成（意図的に簡潔なMarkdown）」に分けて作る。AIが大きく読みにくいMarkdownを一気に吐く失敗を避けるのが狙い。

YAMLは**使い捨て・ローカル限定の足場**で、チームには見せない。成果物は最終Markdownのみ。

## 適用範囲

設計書・spec・設計ドキュメント・アーキテクチャノート・proposal・ADR の作成要求。`$ARGUMENTS` に題材が渡る（省略可）。数文で済むメモには大げさなので、その場合は素直に書く。構成要素・関係・リスク・未解決事項が複数あり、散文化の前にレビューする価値があるときに効く。

## フェーズ1: 設計をYAMLに起こす

`${CLAUDE_SKILL_DIR}/yaml-schema.md` を読み、設計をローカルのYAML足場に書く（例: `./design.yaml`）。

- 1 concept = 1エントリ。原子的に分解し、`summary` を散文で水増ししない。
- トレードオフの根拠は `rationale: |` ブロックに置く（診断は無視、清書が読む）。
- YAMLはユーザーの設計意図から**起こす**もので、ソース文書から無批判に抽出しない（抽出は誤読を固定し、以降の全ビューが継承する）。

この `./design.yaml` は最終Markdownができたら捨ててよいスクラッチである旨をユーザーに伝える。

## フェーズ2: 診断して反復（セルフレビュー）

同梱の診断スクリプトでYAMLをMarkdown＋Mermaidのレビュー補助に変換する。

```bash
uv run ${CLAUDE_SKILL_DIR}/diagnose.py ./design.yaml -o ./design-review.md
```

Mermaid対応プレビュー（Obsidian / Zed）で読める。安価かつ決定的（モデルトークン消費なし）で、以下を炙り出す。

- 関係グラフ（全体形を一目で）
- id未設定concept（参照も検出もできない）
- 孤立concept（繋ぎ忘れ）
- 参照切れrelation（存在しないidを指す）
- 重複concept id（後勝ちで無言マージされる）
- `disposition` の無いrisk（ノートしたが未対応）
- ブロッキングな open question
- importance順のconcept一覧（低重要度のノイズが下に沈む → 肥大化を発見）

検出内容をユーザーに示し、**YAML側を**直す（レポートは再生成されるので直さない）。指摘は2種類に分かれる。

- **修正必須の構造欠陥**（id未設定concept・孤立concept・参照切れrelation・重複concept id・disposition無しrisk）はYAMLを直して消す。
- **blocking な open question** は消すべき欠陥ではなく、設計を止めうる未解決事項を意図的に前景化したもの。解決するか、残すと決めてユーザーに明示する。

構造欠陥が無くなるまで再実行する。`--strict` は blocking question も含めて何か残る限り非ゼロ終了するので、blocking question を意図的に残す間は通らない。ゲートに使うなら「構造欠陥0 かつ blocking question を解消済み」を合格と定義すること（「全指摘0」を目指して正当な blocking question を消さない）。

このフェーズがレビューするのは**骨格**であり、最終散文ではない。

## フェーズ3: Markdownへ清書（成果物）

`${CLAUDE_SKILL_DIR}/clean-markdown-rules.md` に従ってYAMLを最終Markdownに清書する。可読性・肥大化抑制の規約はそこに集約してあり、YAMLにどれだけ詳細が溜まっても成果物は締まる。要点は、importanceが順序と詳しさを駆動し、synthesisが先頭と前面を決め、棄却案や審議過程は成果物を膨らませない、ということ。

清書後は最終Markdownを通し読みする。清書の散文は診断が検査していない新規出力なので、人間の一読を前提に出す。診断は通し読みを減らすが、なくしはしない。

## 範囲の注意

- 既定は単一成果物・単一読み手なので synthesis はYAML本体に畳む。同じ設計から読み手別に複数の清書を出したくなったら、そのとき synthesis を読み手別の別ファイルに切り出す（core/view分割の再来）。それ以前には切り出さない。
- YAMLや診断レポートを成果物に貼り付けない。足場は捨て、Markdownが単独で成り立つようにする。
