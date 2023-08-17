import urllib.request
import urllib.error
import os
import errno
from typing import Dict, Tuple, List, Optional


def read_env_file(filename: str) -> Dict[str, str]:
    """
    Read a .env file and return the configuration as a dictionary.
    """
    with open(filename, "r") as env_file:
        env = env_file.read().split("\n")

    ENV = {}
    for line in env:
        line = line.split("=")
        if len(line) == 2:
            ENV[line[0]] = line[1]

    return ENV


def read_episodes(filename: str) -> List[str]:
    """
    Read the episodes from a text file and return them as a list.
    """
    with open(filename, "r") as file:
        episodes = file.readlines()
    return episodes


def get_season_and_episode(
    episode_number: int, seasons: Dict[int, Tuple[int, int]]
) -> Tuple[Optional[int], Optional[int]]:
    """
    Find the season and the adjusted episode number based on the original episode number.
    """
    for season, (start, end) in seasons.items():
        if start <= episode_number <= end:
            return season, episode_number - start + 1
    return None, None


def download_episode(
        download_info: List[str], path: str, seasons: Dict[int, Tuple[int, int]]
) -> None:
    """
    Download the episode if it doesn't exist in the path.
    """
    try:
        episode_number = int(download_info[0].split(" ")[-1])
        season, episode_number_adjusted = get_season_and_episode(episode_number, seasons)

        file_path = f"{os.path.join(path, f'tv/Swiat wedlug Kiepskich/Season {season:02}', f'S{season:02}E{episode_number_adjusted:03}')}.mp4"

        if not os.path.exists(os.path.dirname(file_path)):
            try:
                os.makedirs(os.path.dirname(file_path))
            except OSError as exc:
                if exc.errno != errno.EEXIST:
                    raise

        if not os.path.isfile(file_path):
            print(f"Downloading {download_info[0]}")
            urllib.request.urlretrieve(download_info[1], file_path)

    except urllib.error.HTTPError as e:
        # HTTP errors like 404, 500, etc.
        print(f"HTTP Error for {download_info[0]}: {e.code} - {e.reason}")

    except urllib.error.URLError as e:
        # URL errors like no network connection, or domain name can't be resolved
        print(f"URL Error for {download_info[0]}: {e.reason}")

    except ValueError as e:
        # Handling invalid integer conversion (when episode_number can't be converted to int)
        print(f"Value Error for {download_info[0]}: {e}")

    except Exception as e:
        # General Exception to catch other exceptions that are not specifically handled
        print(f"Failed to download {download_info[0]}: {e}")


def main() -> None:
    env = read_env_file("../.env")
    path = env["ROOT_MEDIA"]

    seasons = {
        1: (1, 38),
        2: (39, 76),
        3: (77, 110),
        4: (111, 133),
        5: (134, 154),
        6: (155, 170),
        7: (171, 186),
        8: (187, 202),
        9: (203, 244),
        10: (245, 265),
        11: (266, 278),
        12: (279, 292),
        13: (293, 307),
        14: (308, 322),
        15: (323, 337),
        16: (338, 352),
        17: (353, 365),
        18: (366, 379),
        19: (380, 392),
        20: (393, 405),
        21: (406, 418),
        22: (419, 431),
        23: (432, 444),
        24: (445, 456),
        25: (457, 468),
        26: (469, 480),
        27: (481, 492),
        28: (493, 504),
        29: (505, 516),
        30: (517, 528),
    }

    episodes = read_episodes("episodes.txt")
    for episode in episodes:
        download_info = episode.split("  ")
        download_episode(download_info, path, seasons)


if __name__ == "__main__":
    main()
