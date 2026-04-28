using System.Collections.Generic;
using System.Linq;
using UnityEngine.Events;

public class MatchMediator : GenericSingleton<MatchMediator>
{
    public UnityEvent<FieldBlock[]> OnMatchFound = new();

    public void NotifyOfMatch(FieldBlock caller, IEnumerable<FieldBlock> fullMatch)
    {
        OnMatchFound?.Invoke(fullMatch.Append(caller).ToArray());
    }
}