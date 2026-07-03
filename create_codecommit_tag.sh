#!/usr/bin/env bash
#
# create_codecommit_tag.sh
#
# 指定した CodeCommit リポジトリの特定ブランチ先端に対して、
# 「指定タグ名 + 実行年月日（サフィックス）」の注釈付き Git タグを作成し、
# リモート（CodeCommit）へ push する。
#
# 使い方:
#   ./create_codecommit_tag.sh [options] <repository-name> <branch-name> <tag-name>
#
# 必須引数:
#   <repository-name>   CodeCommit のリポジトリ名
#   <branch-name>       タグを付与する対象ブランチ名
#   <tag-name>          ベースとなるタグ名（末尾に実行年月日が付与される）
#                       例: release -> release_20260703
#
# オプション:
#   -r, --region   <region> AWS リージョン (デフォルト: ap-northeast-1)
#   -p, --profile  <name>   AWS プロファイル名 (任意)
#   -u, --repo-url <url>    CodeCommit の Git リモート URL を明示指定する
#                           (未指定時は region + repo から自動生成)
#       --separator <char>  タグ名と年月日の区切り文字 (デフォルト: "_")
#       --date-format <fmt> 年月日フォーマット (date書式, デフォルト: "+%Y%m%d")
#   -A, --auto-switch-role  CodeCommit への権限が無い場合に、終了せず
#                           スイッチロール用スクリプトを source して
#                           自動的にスイッチロールを試みる。
#                           (デフォルト: 警告して終了する)
#   -s, --switch-role-script <path>
#                           スイッチロール用スクリプトのパス。別チームが
#                           用意した専用シェルを source で呼び出す。
#                           環境変数 SWITCH_ROLE_SCRIPT でも指定可能。
#   -f, --force             同名タグが既にリモートに存在する場合、既存タグを
#                           削除してから付け替える。
#                           (デフォルト: 同名タグがあれば中止する)
#   -y, --yes               push 前の確認プロンプトをスキップする
#   -n, --dry-run           実際には実行せず、実行内容のみ表示する
#   -h, --help              このヘルプを表示する
#
# 例:
#   ./create_codecommit_tag.sh my-repo main release
#   ./create_codecommit_tag.sh -r ap-northeast-1 my-repo main release
#   ./create_codecommit_tag.sh -p myprofile --dry-run my-repo main release
#   ./create_codecommit_tag.sh -A -s /opt/team/switch_role.sh my-repo main release
#   ./create_codecommit_tag.sh -f my-repo main release   # 同名タグを付け替える
#
# 前提:
#   - 事前に `aws login --remote` で認証済みであること。未認証の場合は
#     警告して終了する。
#   - 実行中の IAM ユーザに CodeCommit への権限が無い場合は、警告して終了する
#     （--auto-switch-role 指定時は自動でスイッチロールを試みる）。
#   - git credential helper による CodeCommit 認証が設定済みであること。
#
# 依存: bash, git, aws CLI, date

set -euo pipefail

# common.sh を読み込む（このスクリプトと同じディレクトリにある想定）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# デフォルト値
# ---------------------------------------------------------------------------
REPO_NAME=""
BRANCH=""
BASE_TAG=""
REGION="ap-northeast-1"
PROFILE=""
REPO_URL=""
SEPARATOR="_"
DATE_FORMAT="+%Y%m%d"
DRY_RUN=false
ASSUME_YES=false
FORCE=false
AUTO_SWITCH_ROLE=false
# 環境変数 SWITCH_ROLE_SCRIPT があればデフォルト値として使う
SWITCH_ROLE_SCRIPT="${SWITCH_ROLE_SCRIPT:-}"

usage() {
  sed -n '2,54p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# 引数解析（オプション + 位置引数 3 つ）
# ---------------------------------------------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r | --region)
      [[ $# -ge 2 ]] || die "オプション $1 には値が必要です"
      REGION="$2"; shift 2 ;;
    -p | --profile)
      [[ $# -ge 2 ]] || die "オプション $1 には値が必要です"
      PROFILE="$2"; shift 2 ;;
    -u | --repo-url)
      [[ $# -ge 2 ]] || die "オプション $1 には値が必要です"
      REPO_URL="$2"; shift 2 ;;
    --separator)
      [[ $# -ge 2 ]] || die "オプション $1 には値が必要です"
      SEPARATOR="$2"; shift 2 ;;
    --date-format)
      [[ $# -ge 2 ]] || die "オプション $1 には値が必要です"
      DATE_FORMAT="$2"; shift 2 ;;
    -A | --auto-switch-role)
      AUTO_SWITCH_ROLE=true; shift ;;
    -s | --switch-role-script)
      [[ $# -ge 2 ]] || die "オプション $1 には値が必要です"
      SWITCH_ROLE_SCRIPT="$2"; shift 2 ;;
    -f | --force)
      FORCE=true; shift ;;
    -y | --yes)
      ASSUME_YES=true; shift ;;
    -n | --dry-run)
      DRY_RUN=true; shift ;;
    -h | --help)
      usage; exit 0 ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done
      break ;;
    -*)
      die "不明なオプション: $1 ( --help を参照 )" ;;
    *)
      POSITIONAL+=("$1"); shift ;;
  esac
done

# 位置引数を割り当て
[[ ${#POSITIONAL[@]} -ge 1 ]] && REPO_NAME="${POSITIONAL[0]}"
[[ ${#POSITIONAL[@]} -ge 2 ]] && BRANCH="${POSITIONAL[1]}"
[[ ${#POSITIONAL[@]} -ge 3 ]] && BASE_TAG="${POSITIONAL[2]}"
[[ ${#POSITIONAL[@]} -gt 3 ]] && die "引数が多すぎます ( --help を参照 )"

# common.sh の run() / confirm() が参照できるよう export
export DRY_RUN ASSUME_YES

# ---------------------------------------------------------------------------
# 入力チェック
# ---------------------------------------------------------------------------
require_command git
require_command aws
require_command date

[[ -n "$REPO_NAME" ]] || die "リポジトリ名が指定されていません ( --help を参照 )"
[[ -n "$BRANCH"    ]] || die "ブランチ名が指定されていません ( --help を参照 )"
[[ -n "$BASE_TAG"  ]] || die "タグ名が指定されていません ( --help を参照 )"

# タグ名を組み立てる（ベースタグ名 + 区切り文字 + 実行年月日）
DATE_SUFFIX="$(date "$DATE_FORMAT")" \
  || die "日付の生成に失敗しました（--date-format を確認してください）"
FULL_TAG="${BASE_TAG}${SEPARATOR}${DATE_SUFFIX}"

# CodeCommit の HTTPS clone URL を組み立てる
#   https://git-codecommit.<region>.amazonaws.com/v1/repos/<repo>
# 認証は git のグローバル設定（認証情報マネージャ等）で済んでいる前提。
if [[ -z "$REPO_URL" ]]; then
  REPO_URL="https://git-codecommit.${REGION}.amazonaws.com/v1/repos/${REPO_NAME}"
fi

# ---------------------------------------------------------------------------
# 実行内容の表示
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  log_warn "dry-run モード: 実際の clone / タグ作成 / push は行いません"
fi

log_info "リポジトリ    : $REPO_NAME"
log_info "リージョン    : $REGION"
[[ -n "$PROFILE" ]] && log_info "プロファイル  : $PROFILE"
log_info "対象ブランチ  : $BRANCH"
log_info "作成タグ      : $FULL_TAG"
log_info "リモート URL  : $REPO_URL"
[[ "$FORCE" == "true" ]] && log_info "force モード   : 有効 (同名タグがあれば削除して付け替え)"
[[ "$AUTO_SWITCH_ROLE" == "true" ]] && log_info "スイッチロール: 自動 (権限不足時に source して切替)"
echo

# ---------------------------------------------------------------------------
# 0) 事前チェック: AWS 認証 と CodeCommit 権限
# ---------------------------------------------------------------------------
# aws CLI に渡す共通引数（REGION / PROFILE）を組み立てる
AWS_ARGS=(--region "$REGION")
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")

# 0-1) 認証チェック（aws login --remote 済みか）
log_info "AWS 認証状態を確認します..."
if ! aws_is_authenticated "${AWS_ARGS[@]}"; then
  log_error "AWS が未認証です。"
  log_error "先に以下を実行して認証してください:"
  log_error "    aws login --remote"
  die "未認証のため処理を中止しました"
fi
log_success "AWS 認証済みを確認しました"

# 0-2) CodeCommit 権限チェック（git 通信 = codecommit:GitPull できるか）
log_info "CodeCommit へ git 通信できるか確認します（GitPull）: $REPO_NAME"
aws_can_access_codecommit "$REPO_URL" && perm_status=0 || perm_status=$?

case "$perm_status" in
  0)
    log_success "CodeCommit への権限を確認しました"
    ;;
  1)
    # 権限なし: スイッチロールが必要
    log_warn "現在の IAM ユーザには CodeCommit への権限がありません。"
    if [[ "$AUTO_SWITCH_ROLE" != "true" ]]; then
      # 警告して終了するモード
      log_error "スイッチロールしてから再実行してください。"
      if [[ -n "$SWITCH_ROLE_SCRIPT" ]]; then
        log_error "    source \"$SWITCH_ROLE_SCRIPT\""
      else
        log_error "    別チーム提供のスイッチロール用シェルを source してください。"
        log_error "    （--switch-role-script でパスを指定できます）"
      fi
      log_error "または --auto-switch-role を付けて自動スイッチロールを有効にしてください。"
      die "CodeCommit 権限が無いため処理を中止しました"
    fi

    # 自動スイッチロールモード
    [[ -n "$SWITCH_ROLE_SCRIPT" ]] \
      || die "自動スイッチロールには --switch-role-script でスクリプトのパス指定が必要です"
    [[ -f "$SWITCH_ROLE_SCRIPT" ]] \
      || die "スイッチロール用スクリプトが見つかりません: $SWITCH_ROLE_SCRIPT"

    log_info "スイッチロール用スクリプトを source します: $SWITCH_ROLE_SCRIPT"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_warn "(dry-run のため source は実行しません。本番では上記を source します)"
    else
      # shellcheck disable=SC1090
      source "$SWITCH_ROLE_SCRIPT"

      # スイッチロール後に再度権限を確認する
      log_info "スイッチロール後の CodeCommit GitPull 権限を再確認します..."
      aws_can_access_codecommit "$REPO_URL" && perm_status=0 || perm_status=$?
      case "$perm_status" in
        0) log_success "スイッチロール後、CodeCommit への権限を確認しました" ;;
        1) die "スイッチロールしても CodeCommit への権限がありません。ロール設定を確認してください" ;;
        *) die "スイッチロール後の権限確認に失敗しました: ${AWS_LAST_ERROR:-不明なエラー}" ;;
      esac
    fi
    ;;
  *)
    # 権限以外のエラー（接続不可・リポジトリ不存在など）
    die "CodeCommit の権限確認に失敗しました: ${AWS_LAST_ERROR:-不明なエラー}"
    ;;
esac
echo

# ---------------------------------------------------------------------------
# 1) 対象ブランチを一時ディレクトリへ浅く clone
#    CodeCommit には Git タグを直接作成する API が無いため、対象ブランチを
#    clone し、ブランチ先端にタグを付けて push する。
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d)"
# 終了時に一時ディレクトリを削除する
trap 'rm -rf "$WORK_DIR"' EXIT

log_info "対象ブランチを取得します（浅い clone）: $BRANCH"
run git clone --quiet --single-branch --branch "$BRANCH" --depth 1 "$REPO_URL" "$WORK_DIR/repo"

# dry-run では clone していないため、以降のリポジトリ操作はスキップする
if [[ "$DRY_RUN" == "true" ]]; then
  log_warn "[DRY-RUN] 以降の処理（重複チェック / タグ作成 / push）は表示のみ:"
  if [[ "$FORCE" == "true" ]]; then
    log_warn "(force モード: 同名タグがリモートに存在する場合は先に削除します)"
    run git -C "$WORK_DIR/repo" push origin ":refs/tags/$FULL_TAG"
  fi
  run git -C "$WORK_DIR/repo" tag -a "$FULL_TAG" -m "Created by $(basename "$0") for branch $BRANCH" HEAD
  run git -C "$WORK_DIR/repo" push origin "refs/tags/$FULL_TAG"
  echo
  log_success "dry-run 完了（実際の変更はありません）"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2) 既存タグとの重複チェック（リモート）
# ---------------------------------------------------------------------------
log_info "リモートに同名タグが無いか確認します: $FULL_TAG"
if git -C "$WORK_DIR/repo" ls-remote --tags origin "refs/tags/$FULL_TAG" \
     | grep -q "refs/tags/${FULL_TAG}$"; then
  if [[ "$FORCE" != "true" ]]; then
    die "タグ '$FULL_TAG' は既にリモートに存在します。付け替える場合は --force を指定してください"
  fi

  # force モード: 既存タグを削除してから付け替える
  log_warn "タグ '$FULL_TAG' は既にリモートに存在します（force モード: 付け替えます）"
  if ! confirm "既存タグ '$FULL_TAG' を削除して付け替えますか?"; then
    log_warn "付け替えをキャンセルしました（ローカルの一時 clone は破棄されます）"
    exit 0
  fi

  log_info "リモートの既存タグを削除します: $FULL_TAG"
  run git -C "$WORK_DIR/repo" push --quiet origin ":refs/tags/$FULL_TAG"
  log_success "リモートの既存タグを削除しました: $FULL_TAG"

  # shallow clone で取得済みのローカルタグが残っている場合に備えて削除する
  if git -C "$WORK_DIR/repo" rev-parse -q --verify "refs/tags/$FULL_TAG" >/dev/null 2>&1; then
    run git -C "$WORK_DIR/repo" tag -d "$FULL_TAG"
  fi

  # 既に削除確認まで済ませたので、以降の push 確認はスキップする
  ASSUME_YES=true
  export ASSUME_YES
fi

HEAD_COMMIT="$(git -C "$WORK_DIR/repo" rev-parse HEAD)"
log_info "タグ '$FULL_TAG' をコミット $HEAD_COMMIT に作成します"

# ---------------------------------------------------------------------------
# 3) 注釈付きタグを作成
# ---------------------------------------------------------------------------
TAG_MESSAGE="Created by $(basename "$0") on $(date '+%Y-%m-%d %H:%M:%S %z') for branch ${BRANCH}"
run git -C "$WORK_DIR/repo" tag -a "$FULL_TAG" -m "$TAG_MESSAGE" "$HEAD_COMMIT"
log_success "ローカルにタグを作成しました: $FULL_TAG"

# ---------------------------------------------------------------------------
# 4) タグをリモートへ push
# ---------------------------------------------------------------------------
if ! confirm "タグ '$FULL_TAG' をリモートへ push しますか?"; then
  log_warn "push をキャンセルしました（ローカルの一時 clone は破棄されます）"
  exit 0
fi

log_info "タグをリモートへ push します: $FULL_TAG"
run git -C "$WORK_DIR/repo" push --quiet origin "refs/tags/$FULL_TAG"
echo

log_success "完了しました: $FULL_TAG ($HEAD_COMMIT)"
