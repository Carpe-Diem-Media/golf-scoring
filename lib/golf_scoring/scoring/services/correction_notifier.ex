defmodule GolfScoring.Scoring.Services.CorrectionNotifier do
  @moduledoc false

  # A delivery error cannot undo an already committed correction. This signal
  # contains only scope identifiers; subscribers must reauthorize their reads.
  def publish(correction, server \\ GolfScoring.PubSub) do
    result = correction.hole_result

    payload = %{
      event_id: correction.event_id,
      round_id: result.round_id,
      playing_group_id: correction.playing_group_id,
      hole_result_id: result.id,
      scorecard_id: result.scorecard_id,
      resulting_revision: result.revision,
      affected_side_result_ids: Enum.map(correction.side_results, & &1.id)
    }

    Phoenix.PubSub.broadcast(
      server,
      "round:#{result.round_id}",
      {:hole_result_corrected, payload}
    )
  rescue
    _ -> {:error, :pubsub_unavailable}
  catch
    :exit, _ -> {:error, :pubsub_unavailable}
  end
end
