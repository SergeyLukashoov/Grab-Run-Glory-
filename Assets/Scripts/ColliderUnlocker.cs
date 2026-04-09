using UnityEngine;

public class ColliderUnlocker : MonoBehaviour
{
    private const string SaveKey = "UnlockedLevel";

    [SerializeField] private Collider[] _colliders;

    private void Start()
    {
        int unlockedLevel = PlayerPrefs.GetInt(SaveKey, 0);

        for (int i = 0; i < _colliders.Length; i++)
        {
            _colliders[i].enabled = i <= unlockedLevel;
        }
    }
}