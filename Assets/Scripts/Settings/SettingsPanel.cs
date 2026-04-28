using UnityEngine;
using UnityEngine.Events;

public class SettingsPanel : MonoBehaviour, IOverlayMenu
{
    [Header("Start State")]
    [SerializeField]
    private bool OpenedAtStart = false;

    [Header("Events")]
    public UnityEvent<IOverlayMenu> OnOpened;
    public UnityEvent<IOverlayMenu> OnClosed;

    private bool _isOpen;

    private void Start()
    {
        _isOpen = OpenedAtStart;

        gameObject.SetActive(_isOpen);

        if (_isOpen)
        {
            OnOpened.Invoke(this);
            MenuCommunicator.Instance.OpenedMenu(this);
        }
    }

    public void OpenOverlay()
    {
        if (_isOpen || MenuCommunicator.Instance.HasMenuOpen)
            return;

        _isOpen = true;

        gameObject.SetActive(true);

        OnOpened.Invoke(this);
        MenuCommunicator.Instance.OpenedMenu(this);
    }

    public void CloseOverlay()
    {
        if (!_isOpen)
            return;

        _isOpen = false;

        OnClosed.Invoke(this);
        MenuCommunicator.Instance.ClosedMenu(this);

        gameObject.SetActive(false);
    }

    public void CallButtonOnOff()
    {
        if (_isOpen)
            CloseOverlay();
        else
            OpenOverlay();
    }

    public void ListenToOpen(UnityAction<IOverlayMenu> callback)
    {
        OnOpened.AddListener(callback);
    }

    public void StopListenToOpen(UnityAction<IOverlayMenu> callback)
    {
        OnOpened.RemoveListener(callback);
    }

    public void ListenToClose(UnityAction<IOverlayMenu> callback)
    {
        OnClosed.AddListener(callback);
    }

    public void StopListenToClose(UnityAction<IOverlayMenu> callback)
    {
        OnClosed.RemoveListener(callback);
    }
}