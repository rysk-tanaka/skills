#!/usr/bin/env python3
"""
CloudWatchログ取得スクリプト。

使用方法:
    uv run cloudwatch_logs.py /aws/lambda/function-name
    uv run cloudwatch_logs.py /aws/lambda/function-name --hours 3
    uv run cloudwatch_logs.py /aws/lambda/function-name --profile my-profile
"""

# /// script
# requires-python = ">=3.12"
# dependencies = ["boto3", "rich", "typer"]
# ///

import os
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import boto3
import botocore.exceptions
import typer
from rich.console import Console
from rich.table import Table

# =============================================================================
# Constants
# =============================================================================

DEFAULT_REGION = "ap-northeast-1"
DEFAULT_HOURS = 1
DEFAULT_MAX_EVENTS = 100
ERROR_MAX_EVENTS = 50
DISPLAY_MAX_EVENTS = 10
MESSAGE_TRUNCATE_LENGTH = 500
STREAM_NAME_MAX_LENGTH = 30
MILLISECONDS = 1000
MAX_PAGINATION_PAGES = 50

ERROR_FILTER_PATTERNS = [
    '{ $.error = "*" }',
    '{ $.status = "failed" }',
    '{ $.levelname = "ERROR" }',
]

# =============================================================================
# Data structures
# =============================================================================


@dataclass
class LogEvent:
    """CloudWatch log event."""

    timestamp: datetime
    message: str
    log_stream_name: str

    @property
    def formatted_time(self) -> str:
        """Format timestamp as string."""
        return self.timestamp.strftime("%Y-%m-%d %H:%M:%S UTC")


@dataclass
class LogSummary:
    """Log summary."""

    total_events: int
    error_count: int
    time_range_start: datetime
    time_range_end: datetime


# =============================================================================
# AWS session
# =============================================================================


def create_aws_session(profile: str | None, region: str) -> boto3.Session:
    """
    Create AWS session.

    Priority: --profile argument > AWS_PROFILE env var > default.
    """
    session_profile = profile or os.environ.get("AWS_PROFILE")
    return boto3.Session(profile_name=session_profile, region_name=region)


# =============================================================================
# Log fetching
# =============================================================================


def calculate_time_range(hours: int) -> tuple[datetime, datetime]:
    """Calculate time range in UTC."""
    end_time = datetime.now(UTC)
    start_time = end_time - timedelta(hours=hours)
    return start_time, end_time


def fetch_log_events(
    logs_client,
    log_group_name: str,
    start_time: datetime,
    end_time: datetime,
    filter_pattern: str | None,
    max_events: int,
) -> list[LogEvent]:
    """
    Fetch log events from CloudWatch Logs.

    Args:
        logs_client: boto3 CloudWatch Logs client
        log_group_name: Log group name
        start_time: Start time (UTC)
        end_time: End time (UTC)
        filter_pattern: Filter pattern (None for all events)
        max_events: Maximum number of events

    Returns:
        List of LogEvent sorted by newest first
    """
    start_timestamp = int(start_time.timestamp() * MILLISECONDS)
    end_timestamp = int(end_time.timestamp() * MILLISECONDS)

    kwargs: dict = {
        "logGroupName": log_group_name,
        "startTime": start_timestamp,
        "endTime": end_timestamp,
        "limit": max_events,
    }

    if filter_pattern:
        kwargs["filterPattern"] = filter_pattern

    events: list[LogEvent] = []
    prev_token: str | None = None

    for _ in range(MAX_PAGINATION_PAGES):
        if len(events) >= max_events:
            break

        # Limit each page to remaining events needed
        kwargs["limit"] = max_events - len(events)
        response = logs_client.filter_log_events(**kwargs)

        for event in response.get("events", []):
            events.append(
                LogEvent(
                    timestamp=datetime.fromtimestamp(
                        event["timestamp"] / MILLISECONDS, tz=UTC
                    ),
                    message=event["message"],
                    log_stream_name=event.get("logStreamName", ""),
                )
            )

        next_token = response.get("nextToken")
        if not next_token or next_token == prev_token:
            break
        prev_token = next_token
        kwargs["nextToken"] = next_token

    events = events[:max_events]

    # Sort newest first
    events.sort(key=lambda e: e.timestamp, reverse=True)
    return events


def search_error_logs(
    logs_client,
    log_group_name: str,
    start_time: datetime,
    end_time: datetime,
) -> list[LogEvent]:
    """
    Search for error logs using multiple patterns.

    Searches with:
    - { $.error = "*" } (python-json-logger format)
    - { $.status = "failed" } (status field check)
    - { $.levelname = "ERROR" } (python logging format)

    Returns deduplicated events sorted newest first.
    """
    all_events: dict[int, LogEvent] = {}

    for pattern in ERROR_FILTER_PATTERNS:
        try:
            events = fetch_log_events(
                logs_client,
                log_group_name,
                start_time,
                end_time,
                pattern,
                ERROR_MAX_EVENTS,
            )
            for event in events:
                timestamp_ms = int(event.timestamp.timestamp() * MILLISECONDS)
                all_events[timestamp_ms] = event
        except botocore.exceptions.ClientError as err:
            if err.response["Error"]["Code"] == "InvalidParameterException":
                continue
            raise

    return sorted(all_events.values(), key=lambda e: e.timestamp, reverse=True)


# =============================================================================
# Display
# =============================================================================


def _truncate(text: str, max_length: int) -> str:
    """Truncate text with ellipsis."""
    text = text.strip()
    if len(text) > max_length:
        return text[: max_length - 3] + "..."
    return text


def display_results(
    console: Console,
    log_group_name: str,
    summary: LogSummary,
    recent_events: list[LogEvent],
    error_events: list[LogEvent],
) -> None:
    """Display results using Rich."""
    # Header
    console.print(f"\n[bold cyan]CloudWatch Logs: {log_group_name}[/bold cyan]")
    console.print(
        f"  期間: {summary.time_range_start.strftime('%Y-%m-%d %H:%M:%S')} - "
        f"{summary.time_range_end.strftime('%Y-%m-%d %H:%M:%S')} UTC"
    )
    console.print(f"  総イベント数: {summary.total_events}")
    console.print(f"  エラー数: {summary.error_count}\n")

    # Recent logs table
    if recent_events:
        console.print(f"[bold]最新ログ（最大{DISPLAY_MAX_EVENTS}件）[/bold]")
        table = Table(show_header=True, header_style="bold cyan")
        table.add_column("時刻", style="cyan", no_wrap=True)
        table.add_column("メッセージ", style="white")

        for event in recent_events[:DISPLAY_MAX_EVENTS]:
            table.add_row(
                event.formatted_time,
                _truncate(event.message, MESSAGE_TRUNCATE_LENGTH),
            )

        console.print(table)
    else:
        console.print("[yellow]ログイベントが見つかりませんでした[/yellow]")

    # Error logs table
    if error_events:
        console.print(
            f"\n[bold red]エラーログ（最大{DISPLAY_MAX_EVENTS}件）[/bold red]"
        )
        error_table = Table(show_header=True, header_style="bold red")
        error_table.add_column("時刻", style="cyan", no_wrap=True)
        error_table.add_column(
            "ストリーム",
            style="yellow",
            max_width=STREAM_NAME_MAX_LENGTH,
        )
        error_table.add_column("メッセージ", style="red")

        for event in error_events[:DISPLAY_MAX_EVENTS]:
            stream = event.log_stream_name
            if len(stream) > STREAM_NAME_MAX_LENGTH:
                stream = "..." + stream[-(STREAM_NAME_MAX_LENGTH - 3) :]

            error_table.add_row(
                event.formatted_time,
                stream,
                _truncate(event.message, MESSAGE_TRUNCATE_LENGTH),
            )

        console.print(error_table)
    else:
        console.print("\n[green]エラーログは見つかりませんでした[/green]")


# =============================================================================
# CLI
# =============================================================================

app = typer.Typer(help="CloudWatchログ取得スクリプト")
console = Console()


@app.command()
def main(
    log_group_name: str = typer.Argument(..., help="ロググループ名"),
    hours: int = typer.Option(
        DEFAULT_HOURS,
        "--hours",
        "-H",
        help="過去N時間のログを取得",
    ),
    filter_pattern: str | None = typer.Option(
        None,
        "--filter-pattern",
        "-f",
        help="フィルタパターン",
    ),
    profile: str | None = typer.Option(
        None,
        "--profile",
        "-p",
        help="AWSプロファイル名",
    ),
    region: str = typer.Option(DEFAULT_REGION, "--region", "-r", help="AWSリージョン"),
    max_events: int = typer.Option(
        DEFAULT_MAX_EVENTS,
        "--max-events",
        "-n",
        help="取得する最大イベント数",
    ),
) -> None:
    """CloudWatchログを取得・検索します。"""
    console.print(
        f"[bold cyan]CloudWatchログ取得[/bold cyan]\n"
        f"  ロググループ: {log_group_name}\n"
        f"  期間: 過去{hours}時間\n"
        f"  リージョン: {region}"
    )

    effective_profile = profile or os.environ.get("AWS_PROFILE")
    if effective_profile:
        source = "引数" if profile else "環境変数"
        console.print(f"  プロファイル: {effective_profile} ({source})")

    # AWS session
    try:
        session = create_aws_session(profile, region)
        logs_client = session.client("logs")
    except Exception as e:
        console.print(f"[red]AWS認証エラー: {e}[/red]")
        console.print(
            "[dim]AWSプロファイルが正しく設定されているか確認してください[/dim]"
        )
        raise typer.Exit(1) from None

    # Time range
    start_time, end_time = calculate_time_range(hours)

    # Fetch logs
    try:
        with console.status("[bold green]ログを取得中...") as status:
            status.update("[bold green]最新ログを取得中...")
            recent_events = fetch_log_events(
                logs_client,
                log_group_name,
                start_time,
                end_time,
                filter_pattern,
                max_events,
            )

            status.update("[bold green]エラーログを検索中...")
            error_events = search_error_logs(
                logs_client,
                log_group_name,
                start_time,
                end_time,
            )

    except logs_client.exceptions.ResourceNotFoundException:
        console.print(f"[red]ロググループが見つかりません: {log_group_name}[/red]")
        raise typer.Exit(1) from None

    except Exception as e:
        error_name = type(e).__name__
        if "AccessDenied" in error_name or "AccessDenied" in str(e):
            console.print(
                f"[red]アクセス拒否: {log_group_name}[/red]\n"
                "[dim]IAM権限 'logs:FilterLogEvents' が必要です[/dim]"
            )
        else:
            console.print(f"[red]ログ取得エラー: {e}[/red]")
        raise typer.Exit(1) from None

    # Summary
    summary = LogSummary(
        total_events=len(recent_events),
        error_count=len(error_events),
        time_range_start=start_time,
        time_range_end=end_time,
    )

    # Display
    display_results(console, log_group_name, summary, recent_events, error_events)


if __name__ == "__main__":
    app()
