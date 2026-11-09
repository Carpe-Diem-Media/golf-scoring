defmodule GolfScoring.Scoring.Services.ScoreQueryNotifier do
  @moduledoc false

  def publish(opened, server \\ GolfScoring.PubSub),
    do: broadcast(opened, :score_query_opened, server)

  def publish_escalated(escalated, server \\ GolfScoring.PubSub),
    do: broadcast(escalated, :score_query_escalated, server)

  defp broadcast(opened, event, server) do
    query = opened.score_query

    payload = %{
      event_id: opened.event_id,
      round_id: query.round_id,
      score_query_id: query.id,
      hole_result_id: query.hole_result_id,
      scorecard_id: query.scorecard_id,
      hole_result_revision: query.hole_result_revision,
      affected_side_result_ids: Enum.map(opened.side_results, & &1.id)
    }

    Phoenix.PubSub.broadcast(server, "round:#{query.round_id}", {event, payload})
  rescue
    _ -> {:error, :pubsub_unavailable}
  catch
    :exit, _ -> {:error, :pubsub_unavailable}
  end
end
