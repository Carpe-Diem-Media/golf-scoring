defmodule GolfScoring.Scoring.Calculators.SideHoleContributorsTest do
  use ExUnit.Case, async: true

  alias GolfScoring.Scoring.Calculators.SideHoleContributors

  test "groups applicable recorded, missing and excluded facts in shotgun order" do
    facts = schedule("a") ++ schedule("b")

    facts =
      Enum.map(facts, fn fact ->
        cond do
          fact.play_index == 0 and fact.round_entry_id == "a" ->
            %{fact | hole_result_id: "result", revision: 2}

          fact.play_index == 0 and fact.round_entry_id == "b" ->
            %{fact | withdrawal_applicability: :not_applicable}

          true ->
            fact
        end
      end)

    assert {:ok, groups} = SideHoleContributors.select(Enum.reverse(facts))
    assert Enum.map(groups, & &1.play_index) == Enum.to_list(0..17)

    assert %{round_hole_id: "hole-8", recorded: [recorded], missing: [], excluded: [excluded]} =
             hd(groups)

    assert recorded == Enum.find(facts, &(&1.hole_result_id == "result"))
    assert excluded.round_entry_id == "b"
    assert %{recorded: [], missing: [_, _], excluded: []} = Enum.at(groups, 1)
  end

  test "distinguishes two, one and zero recorded candidates without inventing scores" do
    facts =
      for entry <- ["a", "b"], fact <- schedule(entry) do
        case fact.play_index do
          0 -> %{fact | hole_result_id: "result-#{entry}", revision: 1}
          1 when entry == "a" -> %{fact | hole_result_id: "one", revision: 3}
          1 -> %{fact | withdrawal_applicability: :not_applicable}
          2 -> %{fact | withdrawal_applicability: :not_applicable}
          _ -> fact
        end
      end

    assert {:ok, [two, one, zero | _]} = SideHoleContributors.select(facts)
    assert length(two.recorded) == 2
    assert [%{hole_result_id: "one", revision: 3}] = one.recorded
    assert length(one.excluded) == 1
    assert zero.recorded == [] and zero.missing == [] and length(zero.excluded) == 2
  end

  test "rejects unresolved, duplicate, incomplete and inconsistent facts" do
    facts = schedule("a") ++ schedule("b")
    [first | rest] = facts

    assert {:error, :invalid_input} =
             SideHoleContributors.select([
               %{
                 first
                 | withdrawal_applicability: :unresolved,
                   unresolved_reason: :missing_withdrawal_ruling
               }
               | rest
             ])

    assert {:error, :invalid_input} = SideHoleContributors.select([first | facts])
    assert {:error, :invalid_input} = SideHoleContributors.select(rest)

    assert {:error, :invalid_input} =
             SideHoleContributors.select([%{first | play_index: 18} | rest])

    assert {:error, :invalid_input} = SideHoleContributors.select([%{first | revision: 1} | rest])

    assert {:error, :invalid_input} =
             SideHoleContributors.select([%{first | round_hole_id: "other"} | rest])

    assert {:error, :invalid_input} = SideHoleContributors.select([])
  end

  defp schedule(entry) do
    for index <- 0..17 do
      %{
        round_entry_id: entry,
        round_hole_id: "hole-#{rem(index + 8, 18)}",
        play_index: index,
        hole_result_id: nil,
        revision: nil,
        withdrawal_applicability: :applicable,
        ruling_id: nil,
        unresolved_reason: nil
      }
    end
  end
end
