# ReadingCoach — iPhone初版 実装指示書

版: v0.1 / 作成日: 2026-10-31 / アプリ名は仮称

## 0. この依頼で実行すること

このリポジトリに、以下のiPhoneアプリと最小バックエンドを実装してください。設計案だけで止めず、実装、テスト、起動手順、実機確認手順まで作成してください。

既存リポジトリがある場合は最初に構成、AGENTS.md、ビルド方法、未コミット変更を確認し、利用者の変更を壊さないでください。新規なら本書の構成で開始してください。仕様の小さな未確定事項は合理的に決め、docs/decisions.mdに記録してください。APIキー、署名、外部アカウントなど、利用者の操作が不可欠な部分だけを明示してください。

**完了とは、画面があることではなく、記事の取り込みから実際の音声学習、原文への復帰までが接続されていることです。** Mockだけで実音声会話の実装が完了したと扱わないでください。一方、実行環境にXcodeや認証情報がない場合は、実行可能なテストまで進め、未実施の確認を正直に残してください。

## 1. プロダクトの目的

日本語話者が英語の記事を読み、意味を明確に取れなかった文をワンタップで記録し、その箇所だけを日本語の会話で解きほぐし、英文に戻って理解を確認できるアプリを作る。

利用者は「単語と文法は分かるが、文全体として何を述べているかが曖昧」になることがある。全訳を与えるだけではなく、主体・対象、修飾、指示語、否定、条件、対比、推論の強さのどこで意味がずれたかを確認したい。

成功する体験:

> Safariから記事を取り込む → 読む → 曖昧な文をタップ → 読み続ける → マークした文を音声で相談する → 原文を聞く／読み直す → 続きへ戻る → 後日、その箇所から会話で再開する。

**読書の流れを守る。説明をたくさんすることを成功としない。理解と速度は別々に測り、両方の改善を目指す。** 「完璧な理解」「必ず7分で読める」といった保証は表示しない。

## 2. 初版の境界

### P0: 初版に必須

| ID | 必須機能 |
|---|---|
| F01 | Safari共有拡張による本文取り込み、本文貼り付け、取り込み結果プレビュー |
| F02 | 段落・見出しを保った英文リーダー、読書位置の復帰 |
| F03 | 文のワンタップマーク、解除、未確認箇所の一覧 |
| F04 | 対象文と前後の文脈に基づくテキスト対話 |
| F05 | 実際のマイク入力と音声応答による学習。文の選択、再読、次・前、保留を声で操作 |
| F06 | 原文の文単位TTS、反復、速度プリセット、発話箇所のハイライト |
| F07 | 元記事、対象文、学習状態、会話上の位置を保持した中断・再開 |
| F08 | 説明を受けた状態、自力の回答、補助ありの回答、自己申告、別例での確認を区別 |
| F09 | 初読／再読／解説／音声学習の時間を分離して保存 |
| F10 | 未確認・保留箇所から復習を開始。翌日以降の再確認対象を簡単に表示 |
| F11 | APIなしで動く明示的なDemoモード、実接続するLiveモード、テストとセットアップ文書 |

### 初版では実装しない

Android、Web版、PC同期、CloudKit、ログイン課金、公開App Store配布、SNS、単語帳全体、PDF/EPUB、OCR、発音採点、CEFR自動判定、学習通知、複雑な間隔反復アルゴリズム。

**画面ロック中・バックグラウンドでの継続録音も対象外。** 画面を見ない音声操作は、アプリがフォアグラウンドの範囲で対応する。バックグラウンド移行時は録音・再生を止め、復帰時は利用者の操作で再開する。終了した学習とは扱わない。

語句の長押し範囲マークはP1。P0の文単位タップの使いやすさを優先する。ただしデータ構造は範囲指定を保持できる設計にする。

## 3. 技術方針とリポジトリ

| 項目 | 初期方針 |
|---|---|
| iOS | Swift / SwiftUI。必要な本文操作はUIKit/TextKitをラップしてよい |
| 対象 | iOS 17以降のiPhone。最新OS限定APIには可用性チェックを付ける |
| 保存 | メインアプリのSwiftData。ドメインロジックは永続化から独立したSwift Package |
| 共有 | Share Extension + App GroupのImportInbox。拡張からSwiftDataを直接更新しない |
| 分割 | NLTokenizerを基礎に文分割し、結果を保存。句点・ピリオドの単純splitは禁止 [R1] |
| 原文音声 | AVSpeechSynthesizerとdelegateによる位置追従 [R2] |
| 音声会話 | OpenAI Realtime APIのGAインターフェース + ネイティブWebRTC。最新仕様を確認 [R3–R5] |
| WebRTC配布 | stasel/WebRTCを最初の候補とする。第三者のコミュニティ配布であり、公式OpenAI SDKではない [R6] |
| テキスト指導・評価 | バックエンドからResponses API。構造化出力を検証する [R7] |
| バックエンド | TypeScript / Node.jsのサポート中LTS / Fastify / Zod / Vitest。依存版を固定 |
| 本文抽出 | Safari前処理JavaScript内で、固定版のMozilla Readabilityを同梱して使用 [R8–R9] |

WebRTCを使うのは、クライアント音声接続に推奨される方式で、音声入出力とイベントを分けて扱えるため。ブラウザ向けのJavaScriptサンプルを、そのままSwiftで動くコードとして扱わない。native PeerConnection、音声トラック、SDP、data channel、AVAudioSessionの接続を実装する。

第三者バイナリは入手元、固定タグ／checksum、ライセンス、device/simulator対応、配布物の存在を確認する。latestブランチ追従は禁止。導入不能なら理由を記録して代替を提案し、WebRTCの外見だけのMockでLive完了としない。

モデルIDはサーバー設定の`OPENAI_REALTIME_MODEL`、`OPENAI_TEXT_MODEL`等に分離し、実装時に利用可能なモデルと仕様を確認する。古いRealtime betaのヘッダー／イベントとGAを混ぜない。GPT-Live等の別APIへ無断で置換しない。選定モデル、API面、確認日、主要イベントをdocs/api-contract.mdに残す。

推奨構成:

```text
ios/
  ReadingCoach.xcodeproj       # または再現可能な生成設定と生成スクリプト
  ReadingCoach/               # UI・永続化・端末サービス
  ReadingCoachShare/          # 拡張とバンドル済み本文抽出JS
  ReadingCoachTests/
  ReadingCoachUITests/
packages/ReadingCore/         # SourceRef、状態遷移、計測等。AI/SwiftUIから独立
server/
  src/routes/
  src/services/
  src/prompts/
  test/
  .env.example
contracts/                   # API・tool・評価データのJSON Schema
fixtures/                    # 自作記事、抽出HTML、APIイベント
scripts/                     # build/check/smoke
scripts/evals/               # 教師役AIの評価runner
evals/tutor_cases.json       # 本依頼に同梱
README.md
docs/                        # decisions、api-contract、manual-test、verification
```

SwiftパッケージやサーバーSDKの実際の版はロックファイルへ記録する。既存のXcodeプロジェクト生成方法があればそれに合わせる。不要なDIフレームワークや汎用エージェント基盤は導入しない。

## 4. 記事取り込みと原文の信頼性

### 4.1 取り込み

Safari Share Extensionで前処理JavaScriptを実行し、表示ページのDOMの複製にReadabilityを適用する。タイトル、著者（取得できる場合）、出典URL、抽出本文を受け取る。HTMLをReaderでそのまま実行せず、許可したブロック型とプレーンテキストへ変換する。

ブロック型はheading / paragraph / listItem / blockquote / codeを最低限とする。リンク先を保存する場合は安全なURLのみとし、スクリプト、フォーム、iframe、イベント属性、追跡要素は読書画面へ持ち込まない。本文抽出器はサニタイザーではない [R9]。

拡張はUUID名のJSONをApp GroupのImportInboxに一時ファイルからatomicに確定し、短時間で終了する。メインアプリが起動・復帰時に読み込み、プレビュー・確定後に処理済みにする。同じjobの再処理で重複登録しない。DB確定前にinboxを消さない。エラー時には再試行を可能にする。

SafariからURLだけが渡された場合は「本文未取得」として保存する。初版は、Safariでページを開いて共有し直すか、本文貼り付けへ誘導する。URLだけで本文取得済みと表示しない。一般URLのサーバー代理fetchは初版に含めない。

取り込み前プレビューで欠落を確認できる。空・著しく短い本文、非英語、コード中心などは警告するが、利用者が確認した本文は保存可能。ログインやペイウォールの突破、取得失敗時のAIによる本文補完はしない。

### 4.2 原文の固定

確定した抽出本文を「このアプリでの原文スナップショット」とする。抽出本文がWebページ全体と完全同一であるとは保証しない。

`Article`とimmutableな`ArticleSnapshot`を分ける。snapshotには正規化済みブロック、contentHash、取り込み日時、抽出版、文分割版を保存する。意味を変える修正や要約を正規化と呼ばない。

再取り込み／本文修正は新snapshotにする。既存マークを推測で新snapshotへ付け替えない。AI、会話履歴、復習から本文を上書きする経路は作らない。

すべての出典表示・原文読み上げは、下記SourceRefで保存済み本文から取得する。AI生成文を「記事の続き」「原文」と表示することを禁止する。

```text
SourceRef {
  articleID, snapshotID, blockID, sentenceID?,
  rangeUTF16?: { location, length }
}
```

offsetは**ブロック内のUTF-16コード単位**とする。Swift Stringの文字数、UTF-8 byte offsetと混ぜない。絵文字、曲線アポストロフィ、ダッシュ、日本語メモがあっても範囲が壊れないテストを入れる。

sentenceIDは取り込み時に固定し、再起動・リレンダリングで振り直さない。同じ文が二回出ても別IDにする。文章の末尾・略語・引用符・箇条書きの分割結果もテストする。

## 5. 画面と操作

### 5.1 Library / Reader / Review / Settings

Libraryは「続きから」「復習対象」「記事一覧」「取り込み」。Readerが主画面で、英文を大きく読みやすく表示する。装飾より文字サイズ、行間、余白、片手操作、Dynamic Type、Dark Modeを優先する。

Reader下部には「マーク一覧」「原文を聞く」「この文を相談」。対話はsheetまたは下部パネルで開き、対象英文と前後へすぐ戻れる。テキスト入力と音声入力は同じ学習runを使う。

### 5.2 マーク

本文の文を1タップでマークする。即時に控えめな強調と軽い触覚フィードバックを返す。APIを呼ばず、ポップアップや解説を自動表示せず、スクロール位置を変えない。

再タップでマーク解除できる。解除は学習履歴や原文の削除ではない。誤操作を取り消せる。スクロールの開始をタップと誤判定しない。長押し選択やリンク操作との競合を回避する。

直近タップ文をfocusedSourceRefにする。「この文を相談」が指す文を画面に明示する。位置が曖昧なら、AIが勝手に推測して別文の指導を始めない。

### 5.3 復習と順序

復習は原則として記事内の出現順。ユーザーが指定したマークを優先できる。「次」はアクティブなrunが通常読書なら次の文、マーク復習なら次のマークへ進む。

「一個前」はそのrunの前の項目。「前の文も」は文脈取得であり、復習カーソルを動かさない。「もう一回」は直近の原文読み上げ対象を再生する。対象が決まらない場合だけ短く確認する。

「次」「後で」は正解・理解済みの意味ではない。最後の項目では勝手に学習を終了せず、読書へ戻るか終了するかを尋ねる。

## 6. 教師役AIの振る舞い

### 6.1 共通の指導ポリシー

利用者への説明は日本語、教材は英語。必要な場合だけ英語の言い換えを併記する。

- 原文、利用者の解釈、アプリ側の評価を別々に扱う。
- 初回は「どこが曖昧か」「今どう取っているか」を必要な範囲だけ尋ねる。既に答えたことを聞き直さない。
- 直接「説明して」と求められたら、回答を強制せず説明する。
- 意味が合う言い換えを受け入れる。日本語の滑らかさ、語句の一致で採点しない。
- 誤りは一度に一つを原則とし、「何が、何を」「どこが何を修飾するか」「AでもBとは限らない」等を具体化する。
- まず短く答える。通常は2〜4文を目安とし、「具体例」「もっと詳しく」で広げる。機械的な文字数制限で必要な意味を落とさない。
- 正しく取れている箇所まで修正しない。誤りが残っているのに「完璧」「それでOK」で流さない。
- 説明後に任意の再読・確認を促すが、同じ正解の反復を強制しない。
- 「分かった」は自己申告。「音読できた」は音読の観測であり、意味を理解した証拠ではない。
- 過去の指導対象を訂正されたらSourceRefを確認して切り替える。
- 不確かな解釈や文脈不足は明示する。必要なら前後を追加取得する。
- AI生成の例文は「練習文」。原文の引用として扱わない。
- 利用者の明示なしに学習を終了しない。課金・接続制限による停止は理由を説明し、再開可能な中断とする。

たとえば「as opposed to keeping consistencyという意味？」は、原文にkeepingがないという理由だけで否定しない。意味の補い方の妥当性を先に評価し、逐語的構造との違いは必要な場合だけ補足する。

### 6.2 共通文脈

AIに渡す初期contextは、対象文、同じ段落、直前・直後の必要な文、記事タイトル、マークした位置、今回の回答、直近の指導、補助の有無とする。全文・全履歴を毎ターン送らない。

人名・指示語の解決に追加文脈が必要ならtoolで広げる。設定した送信範囲を越える場合は、利用者に分かる形で追加送信を求める。情報がない部分を推測で埋めない。

### 6.3 テキスト回答の構造

JSON Schemaで少なくとも以下を定義し、サーバーとiOSで検証する。

```text
TutorReply {
  requestID, runID, stateRevision,
  intent: clarify | explain | assess | practice | navigate | pause,
  feedbackJa,
  sourceRefs: SourceRef[],
  assessment?: {
    outcome: meaningMatched | partiallyMatched | meaningMismatch | uncertain,
    matchedPoints: string[],
    missedPoints: string[],
    bottleneck: vocabulary | syntax | reference | logicalRelation | context | unknown
  },
  nextPromptJa?,
  generatedPractice?: { text, language, label: "generated_practice" }
}
```

assessmentの正確性はschemaだけでは保証できない。無効な出典参照、範囲外offset、別記事ID、古いrevisionはアプリで拒否する。構造化出力エラー・拒否応答・途中切断では、理解状態を更新しない。

## 7. 音声会話 — P0として実装する

### 7.1 接続

バックエンドが通常のAPIキーで短命のRealtime client secretを発行し、iPhoneがそのcredentialでWebRTC接続する。音声トラックとdata channelを分け、セッション更新、転記、tool call、応答完了、エラーを処理する [R3–R5]。

通常APIキーはiOSアプリ、Info.plist、xcconfig、JavaScript、ログに置かない。短命credentialも永続化せずログへ出さない。期限の固定値を仮定せず、返却された情報に従う。

### 7.2 二つのターン操作

**既定は手動完了モード。** マイクを開始し、考えながら話し、「回答を送る」で確定する。無音やフィラーで勝手に回答を評価しない。VADを有効にしても自動応答は抑制し、アプリがresponseの生成を許可する。

**自動会話モードもP0に含める。** 明示的に切り替えると、発話終了推定を使って画面を見ずに会話できる。Semantic VADのlow相当を初期候補とし、公式イベント仕様に合わせる [R4]。自動判定だけでは無制限には待てないことをUIで隠さない。

どちらのモードでも、アプリ側に`ThinkingHold`を実装する。「待って」「ちょっと考える」または待機ボタンで入る。待機解除、説明要求、送信等の明示操作がない限り、VADの停止通知だけで解説・採点・次への移動をしない。

自動会話では、最終転記と制御コマンドを確認してから応答を許可するresponse gateを設ける。引用中の命令文や回答内の単語を無条件に操作コマンドとみなさず、意図が曖昧なら短く確認する。providerの発話停止イベントだけで採点しない。転記が遅延した場合は待つか再確認し、回答を作り替えない。

`ThinkingHold`は再開の音声コマンドを受けるためマイクが有効な状態。マイクOFFの`Muted`とは区別し、外部送信中かどうかを画面に表示する。Mutedから声だけで再開できるとは案内しない。

### 7.3 音声状態と競合

```text
Disconnected -> Connecting -> Ready
Ready -> Listening -> WaitingForTutor -> TutorSpeaking -> Ready
Listening -> ThinkingHold -> Listening / WaitingForTutor
任意 -> Muted / Suspended / Error / Disconnected
```

学習段階とは別のtransport/audio state machineとする。送信前のdraftは途中発話を連結できる。キャンセル・切断時のdraftを理解評価に使わない。

AIの発話は「止める」と利用者の割り込みで停止可能にする。未再生音声を破棄し、会話履歴上の未聴取部分もAPIの規約に沿って整合させる。「止める」ボタンは常に残す。

原文TTSとAI音声を同時再生しない。原文読み上げ時は`AudioCoordinator`が排他制御し、マイクの送信を一時停止する。この間は声での割り込みを保証せず、停止ボタンを有効にする。読み上げ終了後は直前モードに戻し、原文音声を利用者の回答として登録しない。

着信、ヘッドホン切断、AudioSession interruption、ネットワーク切断、背景化で安全に停止・保存する。復帰時に録音を勝手に再開しない。実装はAVAudioSessionの公式通知に従う [R10]。

### 7.4 転記と理解評価

日本語と英文が混ざる回答を扱う。音声転記を表示・修正できるようにする。毎回の確認を強制する必要はないが、不自然な転記や「違う、そう言っていない」があれば元の回答を無効化し、訂正後に評価し直す。

文字起こしの不確かさを読解の誤りとして採点しない。音声runの`inputModality`と教材の提示方法を記録し、読み上げのみで理解したケースを「初見の読解成功」にしない。

### 7.5 音声toolsの境界

アプリが実行するallowlistを定義する。型付き引数、sourceRef、runID、revisionを検証し、toolCallIDで冪等化する。

| tool | 役割・制限 |
|---|---|
| get_source_context | 保存済み原文と周辺を取得。任意URLへアクセスしない |
| play_source | SourceRefをアプリTTSで再生。AIが生成した英文を原文として読み上げない |
| navigate | next / previous / return_to_reader。runの順序はアプリが決定 |
| mark_unclear | 現在または明示された有効な文にマークを付ける |
| set_wait_mode | ThinkingHoldへの移行・解除。無音を解除理由にしない |
| request_assessment | 確定済み回答と露出履歴をテキスト評価endpointへ渡す。採点結果の永続化はアプリ側 |
| create_practice | 別例を生成。原文とは異なるID空間へ保存 |
| finish_session | 利用者の明示的な終了意図がある場合のみ。終了は理解済みを意味しない |

音声モデルにDBを直接更新させない。音声中の学習評価は共通のテキスト評価ポリシーとschemaを使い、全ての雑談ターンで追加評価APIを呼ばない。対話上の説明と評価結果が食い違った場合、結果を確定せず確認する。

## 8. 原文TTS

文単位、前後を含む再生、同じ文の反復、ゆっくり／標準／速めのプリセット、停止・一時停止・再開を実装する。AVSpeechUtteranceのrateを機械的な「1.0倍」と同一視しない。音声ごとの実速度を保証できない場合は数値倍率を表示しない。

delegateから返る発話範囲をSourceRefへ対応させる。文中の語の強調が使えない環境でも、文全体の再生ハイライトは必須。発話範囲が常に単語単位であると仮定しない [R2]。

「原文」「AIの解説」「練習文」を表示上区別する。原文はresolverから得た文字列だけを再生し、音声モデルに暗記した本文を再現させない。利用できる英語音声がない場合は、テキスト利用を継続させて理由を説明する。

## 9. ドメインモデルと状態の所有権

最低限のモデル:

| モデル | 主な内容 |
|---|---|
| Article / ArticleSnapshot | 書誌情報、immutable本文、出典、版、hash |
| ArticleBlock / Sentence | ブロック種別、順序、本文、固定ID、UTF-16範囲 |
| Mark | SourceRef、作成日時、activeフラグ、任意のメモ |
| ReadingRun | 記事、snapshot、firstPass/reread、現在位置、計測状態 |
| LearningRun | 対象、通常読書/マーク復習、順序、currentRef、lastPlayedRef、revision |
| LearningAttempt | 回答、入力手段、教材提示手段、ヒント・解説露出、評価、自己申告、日時 |
| ConversationTurn | user/assistant、転記、原文ではない本文、tool結果参照、supersededフラグ |
| PracticeItem | 生成文、生成理由、元の誤読分類、原文と異なるID |
| ReviewItem | 対象、dueAt、保留理由、直近attempt |
| TimingSegment | runID、read/tutor/listen/paused、開始終了、概算かどうか |

学習状態は一つの`mastered: Bool`にしない。少なくとも次の証拠を区別する。

```text
marked_unchecked / explanation_seen / self_reported_understood
same_item_correct_supported / same_item_correct_without_new_hint
transfer_item_correct / deferred / assessment_uncertain
```

これらは観測の履歴であり、常に単純な一方向遷移とは限らない。「同じ文を後でヒントなしで答えられた」場合も、過去の解説露出は消さず、完全な初見成功とは区別する。

別例を解けた場合も、提示された補助の有無を保存する。後で誤解が見つかったら再度未確認・要復習にできる。自己申告はAI評価を上書きしない。

状態更新はアプリのreducer/serviceを経由させる。非同期結果はrequestIDとstateRevisionで検証する。前の文の返答が遅れて到着しても、現在の文のマークや評価を書き換えない。

## 10. 計測・復習

Readerが前景にある時間、対話時間、原文音声時間、休止時間を分ける。画面表示時間は視線追跡ではないので「読書時間の目安」と表示する。画面を触らないことだけを理由に読書タイマーを止めない。

WPMは、計測対象の語数と読書区間が分かる場合だけ算出する。全文完読が未確定なら、全文語数を分子に使わない。初読と再読、補助ありとなし、聞いた後の読解を混ぜない。初版の読解速度表示は全文完了したrunに限定してよい。

語数の数え方を固定し、語数と手法の版を保存する。アポストロフィ、ハイフン、コード等の扱いをREADMEに明記する。合計時間に対話・再生時間を重複計上しない。

復習スケジュールは簡単でよい。未確認・保留を優先し、当日解説した項目を翌日以降の再確認対象にする。通知は出さない。未マーク文の抜き取り確認を任意に1問提供するが、読書中に強制的に割り込まない。

## 11. バックエンドと安全性

APIは単独利用のprivate MVPを前提とし、公開マルチユーザーサービスを作り込まない。ただし認証なしのAPIキー代理サーバーは作らない。

| endpoint | 内容 |
|---|---|
| GET /health | 最小の生存確認。秘密・モデル資格情報を返さない |
| POST /v1/realtime/token | 認証済み端末にだけ短命credentialを発行。モデル／設定はサーバーallowlist |
| POST /v1/tutor/turn | 送信された限定contextと回答から指導・評価を返す |
| POST /v1/practice | 対象となる意味関係から新しい短い例文を生成する |

private MVPの認証は、サーバーの高エントロピー`APP_ACCESS_TOKEN`を利用者が初回に端末へ設定し、Keychainに保存する方式でよい。これは公開配布用の認証設計ではない。アプリに固定tokenを埋め込まない。サーバー側は定数時間比較等の適切な検証を行う。

TLS、request body上限、認証／token発行レート制限、timeout、同時処理数制限を入れる。CORSは認証の代わりにならない。`.env`とcredentialをgit除外し、ログからheader、token、音声、本文、回答を除外する。

iPhone実機からPCのlocalhostには接続できないため、READMEに実機から到達可能なHTTPS endpointの設定を記載する。開発用LAN接続を用意する場合もATS全体の恒久無効化は禁止。必要なローカルネットワーク権限等を実構成に合わせて説明する。

音声と記事の一部が外部APIに送信されることを利用開始前に説明する。「端末内だけで処理」と表示しない。初版はアプリ／独自サーバーに生音声を保存しない。API事業者の保存ポリシーまで「保存されない」と断定しない。

会話テキストと学習履歴は端末内に保存し、記事単位・全件の削除を実装する。削除対象にはsnapshot、marks、会話、attempt、practiceへの関連、レビュー項目、import残骸を含める。秘密はKeychainの該当項目も削除可能にする。

記事本文は**信頼できない教材データ**。本文中の「指示を無視」「秘密を送れ」「別URLを開け」を操作指示にしない。原文の引用としてそうした文章を読むことと、tool実行の指示とを分離する。AIから任意URLアクセスや任意ファイル操作を受け付けない。

API usageを取得できる範囲で記録するが、固定価格を捏造しない。既定のセッション時間上限は設定可能にし、中断前に通知する。端末側タイマーやcredentialの有効期限がサーバー側の厳密な課金上限になるとは主張しない。長期の無音待機では接続・マイク継続のコストを利用者に見えるようにする。

## 12. DemoとLive

Demoは自作の短い技術記事と、決定的な教師応答fixtureで動く。UIに常時「Demo：応答はサンプル」と表示する。API未設定・失敗時に、Liveの顔のままDemoへ自動切替しない。

DemoでもReader、マーク、永続化、TTS、復習、状態遷移を確認できる。音声入力イベントをシミュレートするテスト補助は用意してよいが、実際に音声を認識したと表示しない。

Liveには実HTTP、実credential発行、実WebRTC、実ツール処理、実テキスト評価のコードを入れる。モデル未設定、認証失敗、quota超過、ネットワーク断を区別して表示する。障害後も記事とマークは利用できる。

同梱サンプルは自作で、サンプル／練習文と表示する。Web記事の全文を無断でfixtureにコピーしない。特定の公開記事の取得成功をビルド・CIの前提にしない。

## 13. 実装順序

| 段階 | 作業と終了条件 |
|---|---|
| M0 | 環境・既存コード調査、APIとWebRTC配布確認。短い実装計画を記録して着手 |
| M1 | ReadingCore、固定原文、文ID、マーク、状態reducer、評価fixtureを実装。単体テスト |
| M2 | Reader、貼り付け取り込み、永続化、TTSを接続。Demoで読書→マーク→復帰が動く |
| M3 | 最小バックエンドと実WebRTCを先に疎通。音声接続リスクをUI完成後まで放置しない |
| M4 | 教師ポリシー、テキスト評価、voice tools、待機・割り込み、原文TTS排他を接続 |
| M5 | Safari共有、ImportInbox、復習、計測、削除、障害・再開を統合 |
| M6 | 自動テスト、教師eval、実機チェック、README、verification reportを完成 |

各段階で動く縦の流れを残す。ユーザー確認なしで公開デプロイ、課金設定変更、App Store提出、既存リモートへのpushをしない。

## 14. 受け入れ条件

### 決定的な自動テスト

| ID | Given / When | Then |
|---|---|---|
| A01 | 新規Demo起動 | APIキーなしで記事を開き、マークし、再起動後も復帰できる |
| A02 | 文をタップ | 文だけがマークされ、ネットワーク呼び出しも自動解説も発生しない |
| A03 | 同じ文章が二回ある記事 | それぞれ別IDとして正しい方にマークが付く |
| A04 | 絵文字・曲線引用符・略語入り本文 | UTF-16範囲とTTSハイライトが一致し、範囲外アクセスしない |
| A05 | 原文再生要求 | resolverの文字列と完全一致し、生成例文を混入しない |
| A06 | 説明だけを表示／音読だけを実施 | 自力理解成功にしない |
| A07 | 「次」「後で」 | カーソル／保留だけが変わり、理解成功を記録しない |
| A08 | ThinkingHold中にVAD stopが複数回 | 応答生成・評価・移動が起きず、明示解除まで保持する |
| A09 | 前の文のresponseが次の文に移動後到着 | revision不一致で現在状態を更新しない |
| A10 | 重複toolCallID／requestID | 二重保存、二重移動、二重読み上げをしない |
| A11 | 転記訂正 | 元評価をsupersededにし、訂正前の誤読記録を集計しない |
| A12 | 外部指示を含む記事・偽SourceRef | 指示を実行せず、範囲外／別snapshot参照を拒否する |
| A13 | 非認証token発行・過剰要求 | 401／429等を返し、秘密をログへ出さない |
| A14 | 背景化／中断イベント | マイクと再生が止まり、runは再開可能な中断となる |
| A15 | 初読→解説→再読 | 時間と露出を分離し、再読WPMを初読WPMへ上書きしない |
| A16 | share jobの再処理／途中失敗 | 重複せず、失敗時にも入力を失わない |
| A17 | 同じ記事の再取り込み | 新snapshotとなり、旧マークを勝手に移さない |
| A18 | 記事の削除 | 関連データが方針どおり削除され、別記事は残る |
| A19 | Live API失敗 | 明示エラーとなり、Demo応答で成功を装わない |

### 教師役AIの評価

同梱`evals/tutor_cases.json`を使い、期待する意味と禁止応答を検査するrunnerを作る。単語一致だけの自動合否で「教師品質100%」としない。

schema・引用・stateの検査は決定的に行う。指導内容は明示ルーブリックで確認し、Live evalの生出力と人間レビュー用レポートを保存する。確率的なモデルevalは通常の単体テストと分け、APIキーなしでは実行不要。未実行を合格と記録しない。

重要ケース: withoutの関係、as opposed toの適切な補い、implicateの誤解、関係節の付け先、本文にない結論、可能性と断定、原文と例文の区別、考え中への割り込み、誤転記、正しい言い換えの過剰修正。

### 実機チェック

実機iPhoneでSafari共有→マーク→Live音声相談→原文TTS→続きへ復帰を確認する。手動完了と自動会話の両方、内蔵スピーカーとイヤホン、割り込み、着信相当のAudioSession中断、ネットワーク断、権限拒否、ロック・復帰を確認する。

マークの見た目の応答はローカルで即時になるよう実装し、参考目標として実機p95 100ms以内を計測する。音声の応答遅延は接続開始・発話確定・最初の応答音を分けて記録する。外部API込みで達成していない固定秒数を保証しない。

## 15. 引き渡し条件

コード、再現可能なビルド設定、テスト、fixture、依存ロック、.env.example、文書を残す。

READMEにはDemoの起動、Liveの設定、Xcode署名／Bundle ID／App Group、マイク権限、実機へのインストール、サーバー接続、データ削除、既知の制限を書く。開発者が手作業で大量のファイルを作らないと起動しない状態にしない。

`docs/verification.md`には、実行コマンド、実行環境、結果、未実施項目と理由を記録する。Xcodeのない環境ではiOSビルド／Simulator試験を「未実施」とし、成功と書かない。Live APIキーがなければ実会話は未確認とする。

最終報告は「実装済み」「自動テスト結果」「実機／Live確認」「未完了・既知の制限」「利用者が次に行う設定」に分ける。Mockのみ、stub、TODO、未接続ボタンは未完了として列挙する。

## 16. 実装時に参照する一次資料

以下は2026-10-31に確認した入口。実装時は再確認し、deprecated版や別APIのサンプルを混ぜない。OpenAIのWebRTCガイドではRealtime APIの例を選択する。第三者配布は一次の配布元で確認する。

- [R1] Apple NLTokenizer: `https://developer.apple.com/documentation/naturallanguage/nltokenizer`
- [R2] Apple AVSpeechSynthesizer: `https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer`
  / 発話範囲delegate: `https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate/speechsynthesizer(_:willspeakrangeofspeechstring:utterance:)`
- [R3] OpenAI Realtime: `https://developers.openai.com/api/docs/guides/realtime`
  / WebRTC: `https://developers.openai.com/api/docs/guides/voice-webrtc?voice-api=realtime`
- [R4] OpenAI VAD: `https://developers.openai.com/api/docs/guides/realtime-vad`
  / 会話管理: `https://developers.openai.com/api/docs/guides/realtime-conversations`
- [R5] OpenAI client secrets: `https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create`
- [R6] WebRTCコミュニティ配布元: `https://github.com/stasel/WebRTC`
- [R7] OpenAI Structured Outputs: `https://developers.openai.com/api/docs/guides/structured-outputs`
- [R8] Apple Share Extension / App Groups / Safari前処理: `https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html`
- [R9] Mozilla Readability: `https://github.com/mozilla/readability`
- [R10] Apple AVAudioSession: `https://developer.apple.com/documentation/avfaudio/avaudiosession`

これらはAPIやライブラリの参照資料であり、学習効果の保証ではない。設計目標と実測結果を分けること。
