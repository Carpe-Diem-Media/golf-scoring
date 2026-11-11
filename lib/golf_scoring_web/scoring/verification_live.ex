defmodule GolfScoringWeb.Scoring.VerificationLive do
  @moduledoc false
  use GolfScoringWeb, :live_view

  alias GolfScoring.Scoring

  @impl true
  def mount(
        %{"event_id" => event_id, "round_id" => round_id, "group_id" => group_id},
        _session,
        socket
      ) do
    {:ok,
     socket
     |> assign(:event_id, event_id)
     |> assign(:round_id, round_id)
     |> assign(:group_id, group_id)
     |> assign(
       :current_path,
       ~p"/player/events/#{event_id}/rounds/#{round_id}/groups/#{group_id}/verify"
     )
     |> assign(:feedback, nil)
     |> refresh()}
  end

  @impl true
  def handle_event(
        "verify",
        %{"id" => id},
        %{assigns: %{context: %{results: results} = context}} = socket
      ) do
    case Enum.find(results, &(&1.hole_result_id == id and &1.actionable?)) do
      nil ->
        {:noreply,
         socket
         |> assign(:feedback, "This result is not available to verify.")
         |> refresh()}

      result ->
        command = %{
          playing_group_id: context.group_id,
          hole_result_id: result.hole_result_id,
          hole_result_revision: result.revision,
          role_assignment_id: context.assignment.id,
          role_assignment_version: context.assignment.version
        }

        message =
          case Scoring.verify_hole_result(
                 socket.assigns.current_player_access_grant,
                 context.event_id,
                 context.round_id,
                 command
               ) do
            {:ok, _} ->
              "Verification saved."

            {:error, _} ->
              "The result or your access may have changed. Review the current information before trying again."
          end

        {:noreply, socket |> assign(:feedback, message) |> refresh()}
    end
  end

  def handle_event("verify", _params, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    case Scoring.load_player_verification_context(
           socket.assigns.current_player_access_grant,
           socket.assigns.event_id,
           socket.assigns.round_id,
           socket.assigns.group_id
         ) do
      {:ok, context} -> assign(socket, :context, context)
      {:error, _} -> socket |> assign(:context, nil) |> assign(:feedback, nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <AppShell.player flash={@flash} page_title="Verify scores" current_path={@current_path}>
        <section :if={is_nil(@context)} id="verification-unavailable" role="status" class="space-y-2">
          <h2 class="text-lg font-semibold">Verification unavailable</h2>
          <p class="text-sm text-base-content/75">
            This verification view is not available for your player access.
          </p>
        </section>
        <section :if={@context} id="verification-results" class="space-y-5">
          <div>
            <h2 class="text-xl font-semibold">Review recorded scores</h2>
            <p id="verification-summary" class="mt-2 text-sm text-base-content/75">
              {Enum.count(@context.results, & &1.actionable?)} captured results need your verification.
            </p>
          </div>
          <p
            :if={@feedback}
            id="verification-feedback"
            role="status"
            aria-live="polite"
            class="text-sm"
          >
            {@feedback}
          </p>
          <p :if={@context.results == []} class="text-sm text-base-content/75">
            No scores have been recorded for this group.
          </p>
          <ul class="divide-y divide-base-300 border-y border-base-300">
            <li
              :for={result <- @context.results}
              id={"result-#{result.hole_result_id}"}
              class="space-y-2 py-4"
            >
              <div class="flex flex-wrap items-baseline justify-between gap-2">
                <h3 class="font-semibold">{result.player_name}</h3>
                <p class="text-sm">Hole {result.display_hole_number}</p>
              </div>
              <p class="text-sm">{result_label(result)}, revision {result.revision}</p>
              <p class="text-sm">{status_label(result.verification_status)}</p>
              <p :if={result.historical_verification_status} class="text-sm text-base-content/75">
                Earlier verification evidence is historical.
              </p>
              <p :if={result.query_review?} class="text-sm font-medium">Score query under review</p>
              <button
                :if={result.actionable?}
                id={"verify-#{result.hole_result_id}"}
                type="button"
                phx-click="verify"
                phx-value-id={result.hole_result_id}
                aria-label={"Verify #{result.player_name}, hole #{result.display_hole_number}, revision #{result.revision}"}
                class="min-h-11 rounded-lg border border-base-content px-4 py-2 text-sm font-semibold hover:bg-base-200 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
              >
                Verify score
              </button>
            </li>
          </ul>
        </section>
      </AppShell.player>
    </Layouts.app>
    """
  end

  defp result_label(%{outcome: :picked_up}), do: "Picked up"
  defp result_label(%{gross_strokes: strokes}), do: "#{strokes} strokes"
  defp status_label(:pending), do: "Verification required"
  defp status_label(:verified), do: "Verified"
  defp status_label(:overridden), do: "Verified by staff exception"
  defp status_label(:superseded), do: "Verification superseded"
end
