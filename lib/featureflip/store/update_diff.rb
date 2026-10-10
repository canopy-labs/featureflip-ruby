require "set"

module Featureflip
  module Store
    # Change detection for Client#on_update.
    #
    # The store receives a *full* snapshot on every poll tick and every SSE
    # `sync`, so notifying on each one would report "everything changed" once
    # per poll interval. These functions reduce a snapshot to the flag keys whose
    # evaluated value could actually have moved.
    #
    # A port of the python SDK's `_updates.py` (itself mirroring js-sdk
    # `core/store.ts`). The semantics are cross-SDK contract, not an
    # implementation detail.
    module UpdateDiff
      module_function

      # Keys whose evaluated value may differ between two snapshots: added,
      # removed and modified flags, then the flags a changed segment or a
      # changed prerequisite drags along with them.
      #
      # Every model is a Struct, so `!=` is an exact config comparison.
      # FlagConfiguration's memoised @variations_by_key is an ivar, not a
      # member, so it does not take part.
      def diff_snapshot(previous_flags, previous_segments, next_flags, next_segments)
        changed = Set.new

        next_flag_keys = Set.new
        next_flags.each do |flag|
          next_flag_keys << flag.key
          previous = previous_flags[flag.key]
          changed << flag.key if previous.nil? || previous != flag
        end
        # Removed server-side: still a change for anyone holding the old value.
        previous_flags.each_key { |key| changed << key unless next_flag_keys.include?(key) }

        changed_segments = Set.new
        next_segment_keys = Set.new
        next_segments.each do |segment|
          next_segment_keys << segment.key
          previous = previous_segments[segment.key]
          changed_segments << segment.key if previous.nil? || previous != segment
        end
        previous_segments.each_key { |key| changed_segments << key unless next_segment_keys.include?(key) }

        unless changed_segments.empty?
          # A segment edit alters evaluation without bumping any flag's version,
          # so the flags referencing it are pulled in by hand. Only incoming
          # flags are scanned: a flag that dropped its reference to a changed
          # segment had its own rules edited and is already reported above.
          next_flags.each do |flag|
            references = (flag.rules || []).any? do |rule|
              rule.segment_key && changed_segments.include?(rule.segment_key)
            end
            changed << flag.key if references
          end
        end

        # Must run last: it walks out from the fully-resolved set, so a flag only
        # the segment scan pulled in still reaches its dependents.
        add_prerequisite_dependents(next_flags, changed)
        changed.to_a.sort
      end

      # Expands +changed+ (a Set, mutated and returned) with every transitive
      # prerequisite dependent.
      #
      # A flag's version covers its own prerequisite rows, not the flags they
      # point at, so toggling a prerequisite bumps only the prerequisite. The
      # dependent's value still flips (to its off variation, PrerequisiteFailed),
      # so it has to be reported by hand. Over-reporting is harmless; this
      # prevents under-reporting.
      #
      # Pass the POST-change flags: a deleted flag's dependents are still
      # present and still carry the now-dangling row, so they stay reachable.
      def add_prerequisite_dependents(flags, changed)
        return changed if changed.empty?

        dependents = {}
        flags.each do |flag|
          (flag.prerequisites || []).each do |prerequisite|
            key = prerequisite.prerequisite_flag_key
            next if key.nil? || key.empty?

            (dependents[key] ||= []) << flag.key
          end
        end
        return changed if dependents.empty?

        # `changed` doubles as the visited set, so a prerequisite cycle
        # (rejected by the server, reachable via a malformed payload) terminates.
        queue = changed.to_a
        until queue.empty?
          (dependents[queue.pop] || []).each do |dependent|
            next if changed.include?(dependent)

            changed << dependent
            queue << dependent
          end
        end
        changed
      end
    end
  end
end
