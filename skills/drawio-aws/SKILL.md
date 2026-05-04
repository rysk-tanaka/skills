---
name: drawio-aws
description: draw.io で AWS アーキテクチャ図を作成（AWS 4 アイコン、カテゴリ別カラー指定付き）
license: MIT
allowed-tools: Bash Write
---

# draw.io AWS Architecture Diagram Skill

draw.io スキルのラッパー。AWS アーキテクチャ図を作成する際の AWS 4 シェイプライブラリの使い方と注意点をまとめたもの。

基本的な draw.io の操作（XML 構造、エクスポート、CLI）は `/drawio` スキルに従う。このスキルは AWS 固有の知識を補完する。

## AWS 4 アイコンのスタイル

直接シェイプ（`shape=mxgraph.aws4.*`）を使用する。`fillColor` は必須 — 指定しないと CLI エクスポート時にアイコンが透過になる。

### ベーステンプレート

```xml
<mxCell id="example" parent="1"
  style="outlineConnect=0;fontColor=#232F3E;gradientColor=none;fillColor=#XXXXXX;strokeColor=none;dashed=0;verticalLabelPosition=bottom;verticalAlign=top;align=center;html=1;fontSize=11;fontStyle=0;aspect=fixed;pointerEvents=1;shape=mxgraph.aws4.SHAPE_NAME;labelBackgroundColor=#FFFFFF;"
  value="Label" vertex="1">
  <mxGeometry height="60" width="60" x="0" y="0" as="geometry" />
</mxCell>
```

### カテゴリ別 fillColor

| カテゴリ | fillColor | 主なシェイプ（直接シェイプ名） |
| --- | --- | --- |
| Compute | `#ED7100` | `lambda_function` |
| Database | `#C925D1` | `dynamodb`, `dynamodb_stream`, `rds`, `aurora` |
| Storage | `#3F8624` | `s3`, `s3_glacier`, `efs` |
| App Integration | `#E7157B` | `sns`, `queue`（SQS）, `eventbridge`, `step_functions` |
| Internet of Things | `#7AA116` | `iot_core`, `iot_greengrass` |
| Management | `#E7157B` | `parameter_store`, `cloudwatch`, `cloudformation` (App Integration と同色は draw.io AWS4 ライブラリの仕様) |
| Networking | `#8C4FFF` | `vpc`, `elb`, `route53`, `cloudfront`, `api_gateway` |
| Security | `#DD344C` | `iam`, `cognito`, `kms`, `waf` |
| General | `#232F3E` | `endpoint`, `client`, `user` |

### 直接シェイプ名の罠

`shape=mxgraph.aws4.X` の `X` は AWS サービス名そのままとは限らない。シェイプ名が間違っていると塗り潰された矩形のみ描画され、アイコンは出ない。検証済みの動作可否は以下。

| サービス | 動作する直接シェイプ名 | 動作しない名前 |
| --- | --- | --- |
| SQS | `queue` | `simple_queue_service`, `sqs` |
| SNS | `sns` | - |
| EventBridge | `eventbridge` | `amazon_eventbridge` |
| Lambda | `lambda_function` | - |
| DynamoDB | `dynamodb` | - |
| IoT Core | `iot_core` | - |

新しいサービスを追加した際は必ず CLI で SVG エクスポートし、アイコンが描画されているか確認する。

`resourceIcon` ラッパー（`shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.X`）を使う代替手段もあるが、矩形背景 + 白アイコンの見た目になるため、直接シェイプとは混在させない。

### グループコンテナのスタイル

グループシェイプでは枠線色に `stroke=` を使用する（通常セルの `strokeColor=` とは異なる。draw.io エディタが生成する仕様）。

**重要**: すべてのコンテナに `container=1;pointerEvents=0;` を付与する。これがないと子要素のドラッグやエッジ接続が正しく動作しない。

```xml
<!-- AWS Cloud -->
<mxCell style="...shape=mxgraph.aws4.group;grIcon=mxgraph.aws4.group_aws_cloud_alt;stroke=#232F3E;fillColor=none;container=1;pointerEvents=0;..." />

<!-- VPC -->
<mxCell style="...shape=mxgraph.aws4.group;grIcon=mxgraph.aws4.group_vpc2;stroke=#8C4FFF;fillColor=none;container=1;pointerEvents=0;..." />

<!-- Availability Zone -->
<mxCell style="...shape=mxgraph.aws4.group;grIcon=mxgraph.aws4.group_availability_zone;stroke=#007CBC;fillColor=none;container=1;pointerEvents=0;..." />

<!-- Corporate Data Center / External -->
<mxCell style="...shape=mxgraph.aws4.group;grIcon=mxgraph.aws4.group_corporate_data_center;stroke=#147EBA;fillColor=none;container=1;pointerEvents=0;..." />

<!-- 論理グループ（破線枠、AWS グループアイコンなし） -->
<mxCell style="rounded=1;whiteSpace=wrap;html=1;fillColor=none;dashed=1;dashPattern=8 4;strokeColor=#666666;verticalAlign=top;align=left;fontSize=14;fontStyle=1;spacingLeft=10;spacingTop=5;strokeWidth=1;container=1;pointerEvents=0;" />
```

## テキストサイズ

| 要素 | fontSize | 用途 |
| --- | --- | --- |
| アイコンラベル | 13 | メインフローおよび補助サービスのラベル |
| 補助アイコンラベル | 12 | DLQ 等の小型アイコン |
| 注釈テキスト | 12 | 補足説明、脚注 |
| セクションラベル | 14 | Data Layer 等のグループラベル（fontStyle=3: bold+italic） |
| コンテナラベル | 14 | AWS Cloud, VPC 等（fontStyle=1: bold） |
| タイトル | 18 | 図全体のタイトル（fontStyle=1: bold） |
| 凡例テキスト | 13 | Legend のテキスト |

ベーステンプレートの `fontSize=11` はデフォルト値。ユーザーから指定がなければ上記を適用する。

## レイアウトガイドライン

- アイコンサイズ: メイン 60x60、補助（DLQ 等）48x48
- ノード間隔: 水平 160px 以上、垂直 120px 以上（ブランチ間 200px 推奨）
- 座標はグリッド 10px 単位に揃える
- メインフロー（左→右）は同じ Y 座標に配置

### コンテナサイズ

コンテナ（AWS Cloud, 論理グループ等）は中身に合わせてタイトに配置する。右や下に大きな余白が残ると「未完成」「ノードを追加し忘れた」印象を与える。

- 最右要素から 20-50px のパディングで右辺を切る
- 最下要素から 20-50px のパディングで下辺を切る
- 凡例は AWS Cloud 外（下部 / 右部）に出すか、コンテナ内の確実に空いている領域に収める

### 多出力ノードの配置

Lambda が複数の宛先に分岐する場合、宛先群の重心 Y に揃えると矢印交差を最小化できる。

- 例: Uplink Lambda が下方の DB 群と右方の SQS に出力する場合 → コンテナ下段に配置すると経路が短く済む
- Bridge 内に Uplink/Downlink を上下に並べる際、対応する x04 の段（DL 行 / UL 行）と Y を合わせる
- 出射ポイントを左 / 右 / 下に分散させ（`exitX/exitY` で制御）、同方向への出射は 30px 以上間隔を空ける

### ラベル配置

デフォルトはアイコン下（`verticalLabelPosition=bottom;verticalAlign=top;align=center`）。
メインフロー矢印と干渉する場合は右側ラベルに切り替える。

```xml
<!-- 右側ラベル（矢印との重なり回避用） -->
labelPosition=right;verticalLabelPosition=middle;verticalAlign=middle;align=left;spacingLeft=10;
```

使い分けの基準。

- 下ラベル: メインフロー上のアイコン（左右にスペースがある）
- 右ラベル: メインフロー経路の近くに配置される補助サービス（Parameter Store, CloudWatch 等）

同じ役割のサービス（監視系、設定系など）はラベル位置を統一する。

### 共有サービスの配置

複数ブランチから参照されるサービス（SSM, CloudWatch 等）は以下に注意する。

- メインフロー矢印と同じ Y 座標に置かない（矢印がアイコンを貫通する）
- ブランチ間の中央付近に配置し、右側ラベルを使用する
- メインフロー矢印の Y と 20px 以上の間隔を確保する

## エッジスタイル

```xml
<!-- メインフロー: 太い実線 -->
<mxCell style="html=1;strokeColor=#232F3E;strokeWidth=2;" edge="1" />

<!-- 補助接続: 細い破線 -->
<mxCell style="html=1;strokeColor=#999999;strokeWidth=1;dashed=1;" edge="1" />
```

### 接続ポイントの制御

`exitX/exitY/entryX/entryY`（0-1）と `exitPerimeter=0` で制御する。

メインフロー矢印と補助線が同じアイコンから出る場合、異なる exit ポイントを使い分ける。

```text
exitY=0.5（中央）→ メインフロー
exitY=0.75 / 0.25 → 補助線（SSM, CW 等への接続）
exitY=0 / 1（上端/下端）→ 補助線（データ層、DLQ への接続）
```

### 矢印の交差回避

異なるソースから同じコンテナ間ギャップを通る矢印は Y 座標が干渉しやすい。

- トリガ矢印（SQS → Lambda 等）の水平区間と、Lambda 出射の垂直区間が同じ Y を通らないように設計する
- 解消できない場合はノード配置自体を見直す（例: Bridge 内の Uplink/Downlink を上下入れ替えて、各 Lambda を主要宛先と同じ Y 帯に置く）
- 単に経路を遠回りさせるより、ノード配置で根本解決する方が後の保守が楽

### DLQ の配置

DLQ はメインフローから外して SQS キューの上または下に配置する。

- 上側ブランチの DLQ → SQS の上（`exitY=0` → `entryY=1`）
- 下側ブランチの DLQ → SQS の下（`exitY=1` → `entryY=0`）
- サイズは 48x48（メインアイコンより小さく）

```text
  [DLQ 48x48]     ← 上側ブランチ
      |  dashed
  [SQS 60x60] ──→ [Lambda]
```

### 凡例（Legend）

図の下部に凡例を配置する。エッジサンプル + テキストラベルの組み合わせ。

```xml
<!-- Main flow サンプル線 -->
<mxCell edge="1" parent="1" style="endArrow=block;html=1;strokeColor=#232F3E;strokeWidth=2;endFill=1;">
  <mxGeometry relative="1" as="geometry">
    <mxPoint x="40" y="610" as="sourcePoint" />
    <mxPoint x="110" y="610" as="targetPoint" />
  </mxGeometry>
</mxCell>
<!-- Auxiliary サンプル線 -->
<mxCell edge="1" parent="1" style="endArrow=block;html=1;strokeColor=#999999;strokeWidth=1;dashed=1;endFill=1;">
  <mxGeometry relative="1" as="geometry">
    <mxPoint x="40" y="640" as="sourcePoint" />
    <mxPoint x="110" y="640" as="targetPoint" />
  </mxGeometry>
</mxCell>
```

## 注意事項

### エッジの parent 設定

同一コンテナ内のセル間 → そのコンテナを parent にする。異なるコンテナ間 → `parent="1"` にする。

```text
aws_cloud 内の A → B    → parent="aws_cloud"
sp_stack 内の C → D     → parent="sp_stack"
parent="1" の X → aws_cloud 内の Y → parent="1"
```

### その他

- `<mxGeometry relative="1" as="geometry" />` はすべてのエッジに必須
- XML 定義順が z-order になる（コンテナ → エッジ → アイコンの順で定義）
- `labelBackgroundColor=#FFFFFF` でラベルがエッジと重なっても読みやすくなる
- `page="0"`（無限キャンバス）を使用する — `page="1"` だとエクスポート時にページ境界が表示される

## CLI エクスポート

`.drawio` ファイルから SVG / PNG にエクスポート。

```bash
drawio --export --format svg --output diagram.svg diagram.drawio
drawio --export --format png --output diagram.png diagram.drawio
```

GitHub の Markdown では SVG をそのまま `![](diagram.svg)` で埋め込める。`.drawio` ファイルも同梱しておくと再編集が容易。
