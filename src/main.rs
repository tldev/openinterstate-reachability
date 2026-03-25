mod exit_poi_linker;

use clap::{Parser, Subcommand};
use sqlx::PgPool;

#[derive(Parser, Debug)]
#[command(
    name = "pike-score",
    about = "Score exit/place reachability against an OSRM dataset"
)]
struct Cli {
    /// Database URL for the reachability seed database
    #[arg(
        long,
        global = true,
        env = "DATABASE_URL",
        default_value = "postgres://osm:osm_dev@localhost:5433/osm"
    )]
    database_url: String,

    /// OSRM base URL used for reachability scoring
    #[arg(long, global = true, env = "OSRM_URL", default_value = "http://localhost:5000")]
    osrm_url: String,

    /// Max number of parallel OSRM requests
    #[arg(long, global = true, env = "OSRM_PARALLELISM", default_value = "16")]
    osrm_parallelism: usize,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug, Clone, Copy)]
enum Command {
    /// Score all unscored exit/place candidate links
    Score,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();
    run(Cli::parse()).await
}

fn init_tracing() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "pike_score=info".into()),
        )
        .init();
}

async fn run(cli: Cli) -> anyhow::Result<()> {
    configure_osrm_env(&cli);
    let pool = connect_pool(&cli.database_url).await?;
    tracing::info!("Connected to reachability database");

    match cli.command.unwrap_or(Command::Score) {
        Command::Score => run_score_reachability(&pool).await,
    }
}

async fn connect_pool(database_url: &str) -> anyhow::Result<PgPool> {
    Ok(sqlx::postgres::PgPoolOptions::new()
        .max_connections(20)
        .connect(database_url)
        .await?)
}

fn configure_osrm_env(cli: &Cli) {
    // SAFETY: called once from main before spawning threads.
    // The reachability module reads these env vars to configure OSRM.
    unsafe {
        std::env::set_var("OSRM_URL", &cli.osrm_url);
        std::env::set_var("OSRM_PARALLELISM", cli.osrm_parallelism.to_string());
    }
}

async fn run_score_reachability(pool: &PgPool) -> anyhow::Result<()> {
    tracing::info!("Scoring reachability from exit_place_links");
    exit_poi_linker::score_and_filter_poi_reachability(pool).await?;
    tracing::info!("Reachability scoring complete");
    Ok(())
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use super::{Cli, Command};

    #[test]
    fn defaults_to_score_command() {
        let cli = Cli::try_parse_from(["pike-score"]).expect("parse default");
        assert!(matches!(cli.command.unwrap_or(Command::Score), Command::Score));
    }

    #[test]
    fn accepts_explicit_score_subcommand() {
        let cli = Cli::try_parse_from(["pike-score", "score"]).expect("parse score");
        assert!(matches!(cli.command.unwrap_or(Command::Score), Command::Score));
    }

    #[test]
    fn accepts_flags_after_score_subcommand() {
        // This is how score.sh invokes pike-score
        let result = Cli::try_parse_from([
            "pike-score",
            "score",
            "--osrm-parallelism", "16",
            "--osrm-url", "http://localhost:5000",
            "--database-url", "postgresql://pike@localhost/pike_scoring",
        ]);
        assert!(result.is_ok(), "score.sh invocation should parse: {:?}", result.err());
    }

    #[test]
    fn accepts_flags_before_score_subcommand() {
        // Alternative invocation with flags before subcommand
        let cli = Cli::try_parse_from([
            "pike-score",
            "--osrm-parallelism", "16",
            "--osrm-url", "http://localhost:5000",
            "--database-url", "postgresql://pike@localhost/pike_scoring",
            "score",
        ]).expect("flags before subcommand should parse");
        assert_eq!(cli.database_url, "postgresql://pike@localhost/pike_scoring");
        assert_eq!(cli.osrm_url, "http://localhost:5000");
        assert_eq!(cli.osrm_parallelism, 16);
    }

    #[test]
    fn accepts_flags_without_subcommand() {
        // Omit subcommand entirely — defaults to Score
        let cli = Cli::try_parse_from([
            "pike-score",
            "--osrm-parallelism", "16",
            "--osrm-url", "http://localhost:5000",
            "--database-url", "postgresql://pike@localhost/pike_scoring",
        ]).expect("flags without subcommand should parse");
        assert_eq!(cli.database_url, "postgresql://pike@localhost/pike_scoring");
        assert!(cli.command.is_none());
    }
}
