#!/usr/bin/env bash
#
# helpers/create_tag.sh
#
# create_codecommit_tag.sh をラッピングする「ヘルパーシェル」。
# チームで固定的に使う値（リージョン / プロファイル / スイッチロール用
# スクリプト / 自動スイッチロールの有無 / リポジトリ名 など）を、この
# ファイル上部の【設定セクション】にあらかじめ埋め込んでおくことで、
# 日々の実行時に指定する引数を極力減らすことを目的とする。
#
# 使い方（既定の想定: repo はプリセット、branch と tag のみ指定）:
#   ./helpers/create_tag.sh <branch-name> <tag-name>
#
# 例:
#   ./helpers/create_tag.sh main release
#   ./helpers/create_tag.sh -n main release          # dry-run
#   ./helpers/create_tag.sh -f develop hotfix         # 同名タグを付け替え
#   ./helpers/create_tag.sh -R other-repo main rel     # repo を都度上書き
#
# 設計上のポイント（ディレクトリを分けても壊れないようにするための考慮）:
#   1) 元スクリプト (create_codecommit_tag.sh) のパスは、このヘルパー自身の
#      位置 (BASH_SOURCE) を基準に絶対パス化して呼び出す。よって、どの
#      カレントディレクトリから実行しても、また helpers/ を別階層に移動しても
#      正しく元スクリプトを見つけられる。
#   2) 元スクリプトは「source ではなく実行 (bash) 」で起動する。これにより
#      元スクリプト内の `source "$SWITCH_ROLE_SCRIPT"` は元スクリプトの
#      実行プロセス内で行われ、その後の git/aws がスイッチ後の認証情報を
#      正しく引き継ぐ。既存のスイッチロール制御をそのまま活かせる。
#   3) スイッチロール用スクリプトのパスは、相対指定だと source 時に呼び出し元
#      CWD を基準に解決され失敗しうるため、ヘルパー側で絶対パス化してから
#      元スクリプトへ渡す。これでディレクトリを分けても source が確実に動く。
#
# 依存: bash
#
# ---------------------------------------------------------------------------

set -euo pipefail

# ヘルパー自身のあるディレクトリ（CWD 非依存で解決）
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===========================================================================
# 【設定セクション】ここを編集して、固定的に使う値をプリセットする。
#   - 指定を補助するパラメータはここに自由に追加できる。
#   - 空文字 "" にしておくと「未設定」＝ 引数や環境変数での指定が必要になる。
# ===========================================================================

# 元となるラップ対象スクリプト（ヘルパーからの相対パスで指定 → 後で絶対パス化）
MAIN_SCRIPT_REL="../create_codecommit_tag.sh"

# リポジトリ名。チームで対象リポジトリが固定なら埋めておくと、実行時に
# branch と tag だけ指定すれば済む。空なら第1位置引数として必須になる。
DEFAULT_REPO_NAME="my-repo"

# AWS リージョン / プロファイル（チーム固定値を想定）
DEFAULT_REGION="ap-northeast-1"
DEFAULT_PROFILE=""

# スイッチロール用スクリプト。別チームが用意した専用シェルのパス。
#   - 相対パスで書いた場合は「このヘルパーのあるディレクトリ」基準で解決する。
#   - 絶対パス (/... や C:/...) で書いた場合はそのまま使う。
#   - 環境変数 SWITCH_ROLE_SCRIPT が設定されていればそちらを優先する。
DEFAULT_SWITCH_ROLE_SCRIPT="${SWITCH_ROLE_SCRIPT:-/opt/team/switch_role.sh}"

# 権限不足時に自動でスイッチロール (source) を試みるか（true/false）
DEFAULT_AUTO_SWITCH_ROLE="true"

# 元スクリプトへ常に渡したい追加オプションがあればここに列挙する。
#   例: 区切り文字や日付フォーマットをチーム標準に固定したい場合など。
#   EXTRA_ARGS=(--separator "-" --date-format "+%Y%m%d")
EXTRA_ARGS=()

# ===========================================================================
# 【設定セクションここまで】以降は通常編集不要。
# ===========================================================================

# 実行時に上書き可能な値（設定セクションの値で初期化）
REPO_NAME="$DEFAULT_REPO_NAME"
REGION="$DEFAULT_REGION"
PROFILE="$DEFAULT_PROFILE"
SWITCH_ROLE_SCRIPT="$DEFAULT_SWITCH_ROLE_SCRIPT"
AUTO_SWITCH_ROLE="$DEFAULT_AUTO_SWITCH_ROLE"

# 元スクリプトへ渡す「実行時トグル系」オプションを溜める配列
PASS_ARGS=()

# ---------------------------------------------------------------------------
# ちょっとしたユーティリティ
# ---------------------------------------------------------------------------
err()  { printf 'ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; echo >&2; usage >&2; exit 1; }

# パスを絶対パス化する。
#   $1: 対象パス, $2: 相対時の基準ディレクトリ
#   絶対パス（/... または Windows ドライブ C:/...）ならそのまま返す。
to_abs_path() {
  local p="$1" base="$2"
  case "$p" in
    /*)          printf '%s\n' "$p" ;;   # Unix 絶対パス
    [A-Za-z]:[\\/]*) printf '%s\n' "$p" ;;   # Windows 絶対パス (C:/... , C:\...)
    "")          printf '%s\n' "" ;;
    *)           printf '%s/%s\n' "$base" "$p" ;;  # 相対 → 基準dirを前置
  esac
}

usage() {
  cat <<EOF
使い方:
  $(basename "$0") [options] <branch-name> <tag-name>
  $(basename "$0") [options] <repository-name> <branch-name> <tag-name>
      ※ 設定セクションで DEFAULT_REPO_NAME を空にした場合は
        repository-name も必須（位置引数の先頭）になる。

必須引数（外から必ず指定が必要なもの。未指定ならエラーで usage を表示）:
  <branch-name>       タグを付与する対象ブランチ名
  <tag-name>          ベースとなるタグ名（末尾に実行年月日が付与される）
  <repository-name>   リポジトリ名（DEFAULT_REPO_NAME が空のときのみ必須）

オプション（プリセットの上書き用。日常的に使うものだけ用意している）:
  -R, --repo <name>       リポジトリ名を上書き
  -r, --region <region>   AWS リージョンを上書き
  -p, --profile <name>    AWS プロファイルを上書き
  -s, --switch-role-script <path>
                          スイッチロール用スクリプトのパスを上書き
  -A, --auto-switch-role  権限不足時に自動スイッチロールする（プリセット上書き）
      --no-auto-switch-role
                          自動スイッチロールを無効化する
  -f, --force             同名タグがあれば削除して付け替える（元スクリプトへ）
  -y, --yes               確認プロンプトをスキップ（元スクリプトへ）
  -n, --dry-run           実行内容の表示のみ（元スクリプトへ）
  -h, --help              このヘルプを表示

現在のプリセット:
  repository-name       : ${DEFAULT_REPO_NAME:-(未設定: 位置引数で必須)}
  region                : ${DEFAULT_REGION}
  profile               : ${DEFAULT_PROFILE:-(未設定)}
  switch-role-script    : ${DEFAULT_SWITCH_ROLE_SCRIPT:-(未設定)}
  auto-switch-role      : ${DEFAULT_AUTO_SWITCH_ROLE}

例:
  $(basename "$0") main release
  $(basename "$0") -n main release
  $(basename "$0") -R other-repo develop hotfix
EOF
}

# ---------------------------------------------------------------------------
# 引数解析（プリセット上書きオプション ＋ 位置引数）
# ---------------------------------------------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R | --repo)
      [[ $# -ge 2 ]] || die "オプション $1 には値が必要です"
      REPO_NAME="$2"; shift 2 ;;
    -r | --region)
      [[ $# -ge 2 ]] || die "オプション $1 には値が必要です"
      REGION="$2"; shift 2 ;;
    -p | --profile)
      [[ $# -ge 2 ]] || die "オプション $1 には値が必要です"
      PROFILE="$2"; shift 2 ;;
    -s | --switch-role-script)
      [[ $# -ge 2 ]] || die "オプション $1 には値が必要です"
      SWITCH_ROLE_SCRIPT="$2"; shift 2 ;;
    -A | --auto-switch-role)
      AUTO_SWITCH_ROLE="true"; shift ;;
    --no-auto-switch-role)
      AUTO_SWITCH_ROLE="false"; shift ;;
    -f | --force)
      PASS_ARGS+=(--force); shift ;;
    -y | --yes)
      PASS_ARGS+=(--yes); shift ;;
    -n | --dry-run)
      PASS_ARGS+=(--dry-run); shift ;;
    -h | --help)
      usage; exit 0 ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done
      break ;;
    -*)
      die "不明なオプション: $1" ;;
    *)
      POSITIONAL+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------------------
# 位置引数の割り当て
#   - DEFAULT_REPO_NAME が設定済み  : 位置引数は <branch> <tag> の2つ
#   - DEFAULT_REPO_NAME が空        : 位置引数は <repo> <branch> <tag> の3つ
# ---------------------------------------------------------------------------
BRANCH=""
BASE_TAG=""
if [[ -n "$DEFAULT_REPO_NAME" ]]; then
  # repo はプリセット済み（-R で上書きされている場合もある）
  [[ ${#POSITIONAL[@]} -ge 1 ]] && BRANCH="${POSITIONAL[0]}"
  [[ ${#POSITIONAL[@]} -ge 2 ]] && BASE_TAG="${POSITIONAL[1]}"
  [[ ${#POSITIONAL[@]} -gt 2 ]] && die "引数が多すぎます"
else
  # repo も位置引数として受け取る
  [[ ${#POSITIONAL[@]} -ge 1 ]] && REPO_NAME="${POSITIONAL[0]}"
  [[ ${#POSITIONAL[@]} -ge 2 ]] && BRANCH="${POSITIONAL[1]}"
  [[ ${#POSITIONAL[@]} -ge 3 ]] && BASE_TAG="${POSITIONAL[2]}"
  [[ ${#POSITIONAL[@]} -gt 3 ]] && die "引数が多すぎます"
fi

# ---------------------------------------------------------------------------
# 必須引数チェック（外からどうしても指定が必要なもの）
# ---------------------------------------------------------------------------
[[ -n "$REPO_NAME" ]] || die "リポジトリ名が指定されていません（-R/--repo か DEFAULT_REPO_NAME）"
[[ -n "$BRANCH"    ]] || die "ブランチ名が指定されていません"
[[ -n "$BASE_TAG"  ]] || die "タグ名が指定されていません"

# ---------------------------------------------------------------------------
# パス解決（ディレクトリを分けても壊れないようにするための肝）
# ---------------------------------------------------------------------------
# 元スクリプトをヘルパー位置基準で絶対パス化
MAIN_SCRIPT="$(to_abs_path "$MAIN_SCRIPT_REL" "$HELPER_DIR")"
[[ -f "$MAIN_SCRIPT" ]] || die "元スクリプトが見つかりません: $MAIN_SCRIPT"

# スイッチロール用スクリプトを絶対パス化（相対時はヘルパー位置基準）
#   → 元スクリプト内の source が CWD に依存せず確実に動くようにする。
if [[ -n "$SWITCH_ROLE_SCRIPT" ]]; then
  SWITCH_ROLE_SCRIPT="$(to_abs_path "$SWITCH_ROLE_SCRIPT" "$HELPER_DIR")"
fi

# ---------------------------------------------------------------------------
# 元スクリプトへ渡す引数を組み立てる
# ---------------------------------------------------------------------------
ARGS=(--region "$REGION")
[[ -n "$PROFILE" ]] && ARGS+=(--profile "$PROFILE")

if [[ "$AUTO_SWITCH_ROLE" == "true" ]]; then
  ARGS+=(--auto-switch-role)
fi
# スイッチロール用スクリプトは、自動スイッチ有無に関わらず渡しておく
# （元スクリプト側で -A 無しの場合の案内メッセージにも使われるため）。
[[ -n "$SWITCH_ROLE_SCRIPT" ]] && ARGS+=(--switch-role-script "$SWITCH_ROLE_SCRIPT")

# 設定セクションの EXTRA_ARGS と、実行時トグル (PASS_ARGS) を付与
[[ ${#EXTRA_ARGS[@]} -gt 0 ]] && ARGS+=("${EXTRA_ARGS[@]}")
[[ ${#PASS_ARGS[@]}  -gt 0 ]] && ARGS+=("${PASS_ARGS[@]}")

# 位置引数（-- で区切り、以降が確実に位置引数として扱われるようにする）
ARGS+=(-- "$REPO_NAME" "$BRANCH" "$BASE_TAG")

# ---------------------------------------------------------------------------
# 実行（source ではなく bash で「実行」する = スイッチロール制御を活かす）
#   exec で元スクリプトのプロセスに置き換え、終了コードをそのまま返す。
# ---------------------------------------------------------------------------
exec bash "$MAIN_SCRIPT" "${ARGS[@]}"
