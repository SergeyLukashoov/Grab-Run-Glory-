using UnityEngine;

public class AudioHandler : MonoBehaviour
{
    [Header("Volume Controls")]
    [SerializeField]
    private float MusicVolume = 1f;
    [SerializeField]
    private float SFXVolume = 1f;
    [SerializeField]
    private float MasterVolume = 2f;


    private void Start()
    {
      
    }

    public void PlayFmodOneShot(string EventDirectory)
    {
    }

    public void ChangeMusicParameter(int ParameterValue)
    {
    }

    public void EndMusicPlayback()
    {
    }

    public void SetMusicVolume(float volume)
    {
        MusicVolume = volume;

    }

    public void SetSFXVolume(float volume)
    {
        SFXVolume = volume;

    }

    public void SetMasterVolume(float volume)
    {
        MasterVolume = volume;

    }

}
