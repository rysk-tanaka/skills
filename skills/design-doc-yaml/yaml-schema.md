# design YAML スキーマ（design/v1）

このYAMLは**使い捨て・ローカル限定の足場**です。チームには見せません。唯一の成果物は
最終的に清書するMarkdownです。スキーマは「診断スクリプトが機械的に読むフィールド」と
「清書LLMが良い散文を書くための根拠」の両方を満たすよう、構造化フィールドと散文ブロックの
ハイブリッドになっています。

スキーマは診断スクリプトの要求が決めます。誰も読まないフィールド（較正されていない
confidenceスコア等）は足さないこと。

## トップレベル

```yaml
version: design/v1

target:
  type: design_doc        # design_doc / spec / adr / proposal など自由
  title: "ドキュメントのタイトル"

concepts: [...]           # 設計の構成要素（必須）
relations: [...]          # 構成要素間の関係（任意だが推奨）
risks: [...]              # リスクとその処理方針（任意）
open_questions: [...]     # 未解決事項（任意）
decisions: [...]          # 決定事項（任意・設計内容なので本体に置く）
synthesis: {...}          # 清書への舵取り（任意）
```

## concepts（必須）

設計の構成要素。1構成要素 = 1エントリ。これが肥大化を防ぐ規律の核なので、
散文で水増しせず原子的に分解すること。

```yaml
concepts:
  - id: c_store                 # 一意（診断が重複を検出する）。relations から参照される
    label: "TokenBucketStore"   # 短い表示名
    summary: "一文で何であるか"
    importance: high            # high / medium / low（清書での扱いの軽重を決める）
    difficulty: high            # high / medium / low（読み手の理解コスト）
    rationale: |                # 任意。なぜこの設計か。清書LLMだけが読む散文ブロック。
      診断スクリプトはここを無視する。設計の「なぜ」をここに書いておくと、
      清書時に根拠つきの説明が生成できる。
```

- `importance` は清書での順序と詳しさを駆動する。low は省略または一行に圧縮される。
- `rationale` は構造化を諦めてよい場所。トレードオフの議論など、フィールドに収まらない
  ニュアンスをここに散文で置く。

## relations（推奨）

構成要素間の関係。診断スクリプトがこれをMermaidグラフ化し、孤立ノードや参照切れを検出する。

```yaml
relations:
  - from: c_middleware    # 既存の concept id
    to: c_store           # 既存の concept id
    type: depends_on      # depends_on / calls / produces / extends など
    label: "トークンを要求"  # 任意。グラフの辺ラベル
```

`from` / `to` は必ず実在する concept id を指すこと。指さないと診断が「参照切れ」を出す。

## risks（任意）

```yaml
risks:
  - label: "プロセスごとの制限"
    description: "実効制限がインスタンス数に比例する"
    severity: high                       # high / medium / low
    disposition: "v1では許容。スケール時に再検討"  # 処理方針。空だと診断が「未処理」を出す
```

`disposition` が空のリスクは「ノートしたが対応を決めていない」状態として診断で炙り出される。

## open_questions（任意）

```yaml
open_questions:
  - id: q_global
    question: "グローバルな制限保証は必要か"
    blocking: true       # true なら診断で「ブロッキング」として強調される
```

## decisions（任意）

レビューで確定した決定。これは**設計内容**なので別ファイルではなく本体に置く。

```yaml
decisions:
  - id: d_middleware
    chose: "アプリ層ミドルウェア"
    over: ["APIゲートウェイ"]
    because: "ルート単位の粒度とテスト容易性"
```

清書では、棄却案（`over`）を長々と書かない。決定に不可欠な場合のみ一行で触れる。

## synthesis（任意・清書への舵取り）

自己レビューで**発見した**提示方針。設計内容ではなく清書への指示。捨てた view.yaml の
経験的な再来。残すのは結論だけで、審議の過程は書かない。

```yaml
synthesis:
  lead_with: c_middleware           # 先頭に置く要素
  foreground:                        # 前面に出すもの
    - "プロセスごとの制限という制約"
  defer_detail:                      # 触れるが主役にしないもの
    - c_metrics
  terse:                             # 簡潔に留めるもの
    - c_config
```

単一成果物・単一読み手を前提に synthesis は本体に畳んでいる。同じ設計から読み手別に
複数の清書を出したくなったら、そのとき初めて synthesis を別ファイルに切り出す
（core/view 分割の再来）。
